// Copyright 2026 Niantic Spatial.

import UIKit

final class HelpOverlayView: UIView {

    // MARK: - UI

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .natural
        label.font = .systemFont(ofSize: 15)
        label.numberOfLines = 0
        return label
    }()

    private let button: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Help", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(.lightGray, for: .disabled)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.clipsToBounds = true
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        return button
    }()

    // MARK: - Initialization

    init(helpText: String) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 8
        clipsToBounds = true
        isHidden = true

        label.text = helpText
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Setup

    /// Adds the overlay to `parent` and installs a "Help" button in `navigationItem`.
    ///
    /// - Parameters:
    ///   - parent: The view to add the overlay into.
    ///   - anchor: The layout anchor the top of the overlay is pinned below (e.g. a status bar's `bottomAnchor`).
    ///   - navigationItem: The navigation item that will receive the "Help" bar button.
    func setup(in parent: UIView, anchoredBelow anchor: NSLayoutYAxisAnchor, navigationItem: UINavigationItem) {
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: anchor, constant: 10),
            leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: 15),
            trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -15),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 80),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        let barButton = UIBarButtonItem(customView: button)
        if barButton.responds(to: Selector(("setHidesSharedBackground:"))) {
            barButton.setValue(true, forKey: "hidesSharedBackground")
        }
        navigationItem.rightBarButtonItem = barButton
    }

    // MARK: - Actions

    @objc private func handleTap() {
        isHidden.toggle()
        superview?.bringSubviewToFront(self)
    }
}
