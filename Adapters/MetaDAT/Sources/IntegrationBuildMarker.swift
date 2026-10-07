// This target intentionally compiles the concrete iOS DAT bridge against the
// pinned vendor package. The implementation remains split into focused files;
// SwiftPM compiles every source in this directory.
import AgentWearLinkCore
import AgentWearLinkMetaDAT
import MWDATCore
import MWDATCamera

public enum MetaDATIntegrationBuildMarker {
    public static let pinnedSDKVersion = "1.0.0"
}
