import Foundation

public actor OpenClawGatewaySupervisor {
    private let connection: OpenClawGatewayConnection
    private let dispatcher: OpenClawRPCDispatcher
    private let state: OpenClawGatewayState
    private let socket: any OpenClawWebSocket
    private let appVersion: String
    private let scopes: [String]
    private let credentials: OpenClawConnectCredentials
    private let clientIdentity: OpenClawGatewayClientIdentity
    private let locale: String
    private let reconnectPolicy: GatewayReconnectPolicy

    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectToken: UInt64 = 0
    private var stopped = true
    private var stopping = false
    private var tickIntervalMilliseconds = 30_000
    public private(set) var transportGeneration: UInt64 = 0

    public init(
        connection: OpenClawGatewayConnection,
        dispatcher: OpenClawRPCDispatcher,
        state: OpenClawGatewayState,
        socket: any OpenClawWebSocket,
        appVersion: String,
        scopes: [String] = ["operator.read", "operator.write"],
        credentials: OpenClawConnectCredentials = .init(),
        clientIdentity: OpenClawGatewayClientIdentity = .backend,
        locale: String = "en-US",
        reconnectPolicy: GatewayReconnectPolicy = .init()
    ) {
        self.connection = connection
        self.dispatcher = dispatcher
        self.state = state
        self.socket = socket
        self.appVersion = appVersion
        self.scopes = scopes
        self.credentials = credentials
        self.clientIdentity = clientIdentity
        self.locale = locale
        self.reconnectPolicy = reconnectPolicy
    }

    public func start() async throws {
        guard stopped, !stopping, reconnectTask == nil else { return }
        stopped = false
        transportGeneration &+= 1

        await dispatcher.setReceiveFailureHandler { [weak self] in
            await self?.dispatcherReceiveLoopFailed()
        }

        do {
            let hello = try await connection.connect(
                appVersion: appVersion,
                scopes: scopes,
                credentials: credentials,
                clientIdentity: clientIdentity,
                locale: locale
            )
            tickIntervalMilliseconds = max(1_000, hello.policy.tickIntervalMs)
            await dispatcher.start()
            startWatchdog()
        } catch {
            stopped = true
            throw error
        }
    }

    public func stop() async {
        guard !stopping else { return }
        stopping = true
        stopped = true
        transportGeneration &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
        await dispatcher.setReceiveFailureHandler(nil)

        // Invalidate ownership before awaiting transport teardown. A reconnect
        // suspended in sleep/connect may resume while this actor is re-entrant,
        // but it can no longer publish dispatcher readiness for this generation.
        reconnectToken &+= 1
        let inFlightReconnect = reconnectTask
        reconnectTask = nil
        inFlightReconnect?.cancel()

        // Retire the transport first so a receive() implementation that does not
        // promptly observe Swift task cancellation is still forced to unwind.
        await connection.disconnect()
        await dispatcher.stop()

        // Do not allow a new start until the retired reconnect task has observed
        // cancellation/token invalidation and completed its cleanup.
        if let inFlightReconnect {
            await inFlightReconnect.value
        }
        stopping = false
    }

    private func dispatcherReceiveLoopFailed() async {
        guard !stopped, !stopping else { return }

        await reconnect(
            closeCode: 1_001,
            closeReason: "transport receive loop failed"
        )
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            await self?.watchdogLoop()
        }
    }

    private func watchdogLoop() async {
        while !Task.isCancelled && !stopped {
            let interval = max(1_000, tickIntervalMilliseconds)

            do {
                try await Task.sleep(for: .milliseconds(interval))
            } catch {
                return
            }

            guard !stopped else { return }

            let running = await dispatcher.isRunning
            let doubledInterval = interval.multipliedReportingOverflow(by: 2)
            let staleTimeout = doubledInterval.overflow
                ? Int.max
                : doubledInterval.partialValue
            let stale = await dispatcher.isStale(
                timeoutMilliseconds: staleTimeout
            )

            if !running || stale {
                await reconnect(
                    closeCode: stale ? 4_000 : 1_001,
                    closeReason: stale ? "tick timeout" : "transport retired"
                )
            }
        }
    }

    func reconnect(
        closeCode: Int,
        closeReason: String
    ) async {
        // Module-internal so deterministic transition tests can drive the
        // reconnect state machine without waiting on the watchdog clock.
        guard !stopped, !stopping else { return }

        // Coalesce every trigger onto one owned reconnect transition. Actor
        // isolation alone is insufficient because the transition is re-entrant
        // at socket, dispatcher, sleep, and handshake awaits.
        if let inFlightReconnect = reconnectTask {
            await inFlightReconnect.value
            return
        }

        reconnectToken &+= 1
        let token = reconnectToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runReconnect(
                closeCode: closeCode,
                closeReason: closeReason,
                token: token
            )
        }
        reconnectTask = task

        await task.value

        if reconnectToken == token {
            reconnectTask = nil
        }
    }

    private func runReconnect(
        closeCode: Int,
        closeReason: String,
        token: UInt64
    ) async {
        guard reconnectIsActive(token) else { return }

        // A reconnect advances transport identity only. In-flight RPC/agent work is
        // intentionally not retained or replayed by the supervisor: its outcome is
        // uncertain once the old transport is retired.
        transportGeneration &+= 1
        await socket.close(code: closeCode, reason: closeReason)
        guard reconnectIsActive(token) else { return }

        await dispatcher.stop()
        guard reconnectIsActive(token) else { return }

        var attempt = 1
        var serverMinimumDelay = 0
        var pairingRequestID: String?
        var pairingDeviceID: String?
        while reconnectIsActive(token) {
            if let maximum = reconnectPolicy.maximumAttempts,
               attempt > maximum {
                // Exhausting the configured budget is terminal for this
                // supervisor generation. Only an explicit start() may create a
                // fresh recovery generation.
                stopped = true
                await state.disconnect()
                return
            }

            await state.beginReconnect(attempt: attempt)
            guard reconnectIsActive(token) else { return }

            let delay = max(
                reconnectPolicy.delayMilliseconds(forAttempt: attempt),
                serverMinimumDelay
            )
            serverMinimumDelay = 0
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }

            guard reconnectIsActive(token) else { return }

            do {
                let hello = try await connection.connect(
                    appVersion: appVersion,
                    scopes: scopes,
                    credentials: credentials,
                    clientIdentity: clientIdentity,
                    locale: locale
                )

                // stop() invalidates the token before tearing down the transport.
                // A late successful handshake must therefore be retired rather
                // than resurrecting dispatcher readiness.
                guard reconnectIsActive(token) else {
                    await connection.disconnect()
                    return
                }

                tickIntervalMilliseconds = max(1_000, hello.policy.tickIntervalMs)
                await dispatcher.start()

                guard reconnectIsActive(token) else {
                    await dispatcher.stop()
                    await connection.disconnect()
                    return
                }
                return
            } catch let error as OpenClawHandshakeError {
                guard reconnectIsActive(token) else { return }
                switch error {
                case let .pairingRequired(pairing):
                    guard Self.shouldRetryPairing(pairing) else {
                        // The server explicitly paused reconnect, marked the
                        // condition non-retryable, or did not request a bounded
                        // wait/retry flow. Explicit start() is the recovery
                        // boundary after external approval/user action.
                        stopped = true
                        return
                    }

                    // A wait-for-resolution flow is tied to one pairing request
                    // and device. If the server starts returning a different
                    // identity while we are waiting, fail closed instead of
                    // manufacturing repeated pairing requests.
                    if pairing.waitForResolution {
                        if let expected = pairingRequestID,
                           let actual = pairing.requestID,
                           expected != actual {
                            stopped = true
                            return
                        }
                        if let expected = pairingDeviceID,
                           let actual = pairing.deviceID,
                           expected != actual {
                            stopped = true
                            return
                        }
                        pairingRequestID = pairingRequestID ?? pairing.requestID
                        pairingDeviceID = pairingDeviceID ?? pairing.deviceID
                    }

                    serverMinimumDelay = max(
                        0,
                        pairing.retryAfterMilliseconds ?? 0
                    )
                    attempt += 1
                default:
                    attempt += 1
                }
            } catch let error as AWLOpenClawError {
                guard reconnectIsActive(token) else { return }
                switch error {
                case let .gateway(_, retryable, _) where !retryable:
                    stopped = true
                    return
                case let .gateway(_, _, retryAfterMilliseconds):
                    serverMinimumDelay = retryAfterMilliseconds ?? 0
                    attempt += 1
                default:
                    attempt += 1
                }
            } catch {
                guard reconnectIsActive(token) else { return }
                attempt += 1
            }
        }
    }

    private nonisolated static func shouldRetryPairing(
        _ pairing: OpenClawPairingRequired
    ) -> Bool {
        guard pairing.retryable, !pairing.pauseReconnect else {
            return false
        }

        return pairing.waitForResolution
            || pairing.recommendedNextStep == "wait_then_retry"
    }

    private func reconnectIsActive(_ token: UInt64) -> Bool {
        !stopped
            && !stopping
            && reconnectToken == token
            && !Task.isCancelled
    }
}
