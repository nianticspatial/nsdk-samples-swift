import Foundation
import SwiftyNsdk

/// Base class for NSDK feature managers that follow a common lifecycle pattern.
class NsdkFeatureManager<SessionType: NsdkFeatureSession> {
    /// The NSDK feature session managed by this instance
    let session: SessionType

    /// Initializes the manager with a specific NSDK session
    /// - Parameter session: The NSDK feature session to manage
    init(session: SessionType) {
        self.session = session
    }

    /// Returns the configuration for the feature session.
    ///
    /// Subclasses must override this method to provide their specific configuration.
    /// The default implementation triggers a fatal error if not overridden.
    ///
    /// - Returns: The configuration object for this feature session
    func configuration() -> SessionType.Configuration {
        fatalError("Subclass must implement configuration()")
    }

    /// Starts the feature session with appropriate configuration.
    ///
    /// This method:
    /// 1. Obtains configuration by calling `configuration()`
    /// 2. Applies the configuration to the session
    /// 3. Starts the session
    /// Subclasses can override this method for custom startup logic.
    func start() {
        let config = configuration()
        do {
            try session.configure(with: config)
        } catch {
            print("Error: failed to configure session - \(error)")
            return
        }
        session.start()
    }

    /// Stops the feature session.
    /// Subclasses can override this method for custom cleanup logic.
    func stop() {
        session.stop()
    }

    /// Gets the current status of the feature session.
    /// - Returns: Feature status flags indicating current state and any issues
    func featureStatus() -> NsdkFeatureStatus {
        return session.featureStatus()
    }
}
