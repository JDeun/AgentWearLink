import Foundation

public actor OpenClawGatewaySupervisor {
    private let connection: OpenClawGatewayConnection
    private let dispatcher: OpenClawRPCDispatcher
    private let state: OpenClawGatewayState
    private let socket: any OpenClawWebSocket
    private let appVersion: String
    private let scopes: [String]
    private let credentials: OpenClawConnectCredentials
    private let locale: String
    private let reconnectPolicy: GatewayReconnectPolicy

    private var watchdogTask: Task<Void, Never>?
    private var stopped = true
    private var tickIntervalMilliseconds = 30_000

    public init(
        connection: OpenClawGatewayConnection,
        dispatcher: OpenClawRPCDispatcher,
        state: OpenClawGatewayState,
        socket: any OpenClawWebSocket,
        appVersion: String,
        scopes: [String] = ["operator.read", "operator.write"],
        credentials: OpenClawConnectCredentials = .init(),
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
        self.locale = locale
        self.reconnectPolicy = reconnectPolicy
    }

    public func start() async throws {
        guard stopped else { return }
        stopped = false

        do {
            let hello = try await connection.connect(
                appVersion: appVersion,
                scopes: scopes,
                credentials: credentials,
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
        stopped = true
        watchdogTask?.cancel()
        watchdogTask = nil
        await dispatcher.stop()
        await connection.disconnect()
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
                try await Task.sleep(
                    nanoseconds: UInt64(interval) * 1_000_000
                )
            } catch {
                return
            }

            guard !stopped else { return }

            let running = await dispatcher.isRunning
            let stale = await dispatcher.isStale(
                timeoutMilliseconds: interval * 2
            )

            if !running || stale {
                await reconnect(
                    closeCode: stale ? 4_000 : 1_001,
                    closeReason: stale ? "tick timeout" : "transport retired"
                )
            }
        }
    }

    private func reconnect(
        closeCode: Int,
        closeReason: String
    ) async {
        await socket.close(code: closeCode, reason: closeReason)
        await dispatcher.stop()

        var attempt = 1
        while !stopped {
            if let maximum = reconnectPolicy.maximumAttempts,
               attempt > maximum {
                await state.disconnect()
                return
            }

            await state.beginReconnect(attempt: attempt)

            let delay = reconnectPolicy.delayMilliseconds(forAttempt: attempt)
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay) * 1_000_000
                )
            } catch {
                return
            }

            guard !stopped else { return }

            do {
                let hello = try await connection.connect(
                    appVersion: appVersion,
                    scopes: scopes,
                    credentials: credentials,
                    locale: locale
                )
                tickIntervalMilliseconds = max(1_000, hello.policy.tickIntervalMs)
                await dispatcher.start()
                return
            } catch let error as OpenClawHandshakeError {
                switch error {
                case .pairingRequired:
                    // Pairing requires explicit external approval. Do not spin.
                    stopped = true
                    return
                default:
                    attempt += 1
                }
            } catch let error as AWLOpenClawError {
                switch error {
                case let .gateway(_, retryable) where !retryable:
                    stopped = true
                    return
                default:
                    attempt += 1
                }
            } catch {
                attempt += 1
            }
        }
    }
}
