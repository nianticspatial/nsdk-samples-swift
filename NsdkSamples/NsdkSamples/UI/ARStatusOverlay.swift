// Copyright 2026 Niantic Spatial.

import UIKit
import ARKit

/// Displays AR tracking status as an overlay bar at the top of the screen.
///
/// Extracted from the old BaseARViewController's sessionInfoView + sessionInfoLabel.
/// Each ViewController that needs tracking feedback can add this overlay and
/// subscribe to ARFrameState's publishers to drive updates.
final class ARStatusOverlay: UIView {

    // MARK: - UI

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.text = "Initializing AR session..."
        return label
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 10
        clipsToBounds = true

        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Setup

    func setup(in parent: UIView) {
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: 10),
            leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - Update

    func update(trackingState: ARCamera.TrackingState, anchorsIsEmpty: Bool) {
        let message: String

        switch trackingState {
        case .normal where anchorsIsEmpty:
            message = "Move the device around to detect horizontal and vertical surfaces."

        case .notAvailable:
            message = "Tracking unavailable."

        case .limited(.excessiveMotion):
            message = "Tracking limited - Move the device more slowly."

        case .limited(.insufficientFeatures):
            message = "Tracking limited - Point the device at an area with visible surface detail, or improve lighting conditions."

        case .limited(.initializing):
            message = "Initializing AR session."

        default:
            message = ""
        }

        label.text = message
        isHidden = message.isEmpty
    }
}
