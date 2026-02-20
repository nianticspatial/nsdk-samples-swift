import UIKit
import ARKit
import SwiftyNsdk

class ObjectDetectionViewController: BaseARViewController, UIGestureRecognizerDelegate {
    // The manager instance
    private var manager: ObjectDetectionManager?

    // State variables
    private var isRunning = false

    // UI Elements
    private let detectedObjectsLayer = CALayer()
    private var startStopButton: UIButton = UIButton()
    private var presenterModeControl: UISegmentedControl!
    private var infoVisible = false
    /// confidence Threshold for object detection
    private var confidenceThreshold: Float = 0.5
    /// Aggregation state to reduce choppy per-frame redraws
    private var aggregatedObjects: [AggregatedObject] = []
    /// How many frames to keep objects around while aggregating
    private let aggregationWindow = 5
    /// How many consecutive frames of larger detections are required before we allow an expansion
    private let expansionHysteresis = 3
    /// Thresholds used for containment/merge decisions
    private let containmentThreshold: CGFloat = 0.9
    private let iouThreshold: CGFloat = 0.8
    /// Presenter responsible for drawing/interaction behavior (Continuous or TapSelect)
    private var presenter: ObjectDetectionPresenter!

    override func setupUI() {
        super.setupUI()

        self.title = "Object detection"
        helpLabel.text = "Object Detection Sample Help\n\nThis sample identifies, identifies and mark objects" +
        " as detected, then draws a bounding box around the object.\nTO USE:\nPress the \"Start\" button," +
        " and move the camera around, pointing at the object or objects you want to identify. Red boxes will " +
        " appear around the objects detected along with their labels and confidence level." +
        "\nTap Mode: \n" +
        " point the camera towards the object you want to identify, then tap and hold in the general area of it." +
        " A yellow bounding box will appear around the object along with it's label and confidence level. Release tap" +
        " to change objects."

    }

    override func viewDidLoad() {
        super.viewDidLoad()

        detectedObjectsLayer.frame = view.bounds
        view.layer.addSublayer(detectedObjectsLayer)

        startStopButton.setTitle("Start", for: .normal)
        startStopButton.setTitleColor(.white, for: .normal)
        startStopButton.backgroundColor = .systemBlue
        startStopButton.layer.cornerRadius = 8
        startStopButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        startStopButton.addTarget(self, action: #selector(handleButtonTap), for: .touchUpInside)
        startStopButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startStopButton)

        NSLayoutConstraint.activate([
            startStopButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            startStopButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            startStopButton.widthAnchor.constraint(equalToConstant: 120),
            startStopButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        // Default presenter: continuous (show all boxes).
        presenter = ContinuousPresenter(overlayLayer: detectedObjectsLayer)

        // Add a segmented control to toggle between continuous and tap-to-select presenters
        presenterModeControl = UISegmentedControl(items: ["All", "Tap"])
        presenterModeControl.selectedSegmentIndex = 0 // default to All
        presenterModeControl.addTarget(self, action: #selector(presenterModeChanged(_:)), for: .valueChanged)
        presenterModeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(presenterModeControl)

        NSLayoutConstraint.activate([
            presenterModeControl.trailingAnchor.constraint(equalTo: startStopButton.leadingAnchor, constant: -12),
            presenterModeControl.centerYAnchor.constraint(equalTo: startStopButton.centerYAnchor),
            presenterModeControl.widthAnchor.constraint(equalToConstant: 120),
            presenterModeControl.heightAnchor.constraint(equalToConstant: 36)
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didReceiveLongPress(_:)))
        longPress.minimumPressDuration = 0.2
        view.addGestureRecognizer(longPress)
        longPress.delegate = self

    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Always return true to allow the possibility of simultaneous recognition
        return true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if (isRunning) {
            manager?.stop()
        }
    }

    @objc private func handleButtonTap() {
        if manager == nil {
            manager = ObjectDetectionManager(nsdk: nsdkManager!.session)
        }

        if isRunning {
            // Stop the feature
            manager!.stop()
            // Clear UI via presenter
            presenter.clear()
        } else {
            // Start the feature
            manager!.start()
        }

        // Update the button label
        isRunning = !isRunning
        startStopButton.setTitle(isRunning ? "Stop" : "Start", for: .normal)
    }

    override func session(_ session: ARSession, didUpdate frame: ARFrame) {
        super.session(session, didUpdate: frame)
        guard let manager = manager, isRunning else { return }

        // Pull the latest object detection results transformed to the UI view
        guard let viewOrientation = view.window?.windowScene?.interfaceOrientation else { return }
        if let detectedObjects = manager.latestDetections(for: view.bounds.size, viewportOrientation: viewOrientation, threshold: confidenceThreshold, frame: frame) {
            // Aggregate detections across a small window of frames to smooth visuals
            // Work on the main thread for layer mutations
            DispatchQueue.main.async {
                // Mark all aggregated objects as unseen for this frame; we'll reset when matched
                for i in 0..<self.aggregatedObjects.count {
                    self.aggregatedObjects[i].unseenFrames += 1
                }

                // Merge current detections into aggregatedObjects
                for object in detectedObjects {
                    let newRect = object.rect
                    var matchedIndex: Int? = nil
                    var bestScore: CGFloat = 0

                    for (index, agg) in self.aggregatedObjects.enumerated() {
                        // compute containment and IoU
                        let inter = intersectionOverUnion(agg.rect, newRect)
                        let newRectArea = area(newRect)
                        let aggRectArea = area(agg.rect)

                        // compute containment ratios
                        let aggContainsNew = newRectArea > 0 ? area(agg.rect.intersection(newRect)) / area(newRect) : 0
                        let newContainsAgg = aggRectArea > 0 ? area(agg.rect.intersection(newRect)) / area(agg.rect) : 0

                        // Prefer containment, otherwise fall back to IoU
                        var score: CGFloat = 0
                        if aggContainsNew >= self.containmentThreshold {
                            score = 1.0 + aggContainsNew
                        } else if newContainsAgg >= self.containmentThreshold {
                            score = 1.0 + newContainsAgg
                        } else {
                            score = inter
                        }

                        if score > bestScore && (score > self.iouThreshold || aggContainsNew >= self.containmentThreshold || newContainsAgg >= self.containmentThreshold) {
                            bestScore = score
                            matchedIndex = index
                        }
                    }

                    if let idx = matchedIndex {
                        // Update or expand the matched aggregated object with hysteresis to avoid single-frame spikes
                        let oldRect = self.aggregatedObjects[idx].rect
                        let oldArea = area(oldRect)
                        let newArea = area(newRect)
                        let growthThreshold: CGFloat = 1.05 // require >5% area increase to consider growth

                        if oldRect.contains(newRect) {
                            // newRect is inside existing -> nothing to change except refresh
                            self.aggregatedObjects[idx].unseenFrames = 0
                            self.aggregatedObjects[idx].className = self.aggregatedObjects[idx].confidence > object.confidence ? self.aggregatedObjects[idx].className : object.className
                            self.aggregatedObjects[idx].confidence = max(self.aggregatedObjects[idx].confidence, object.confidence)
                            self.aggregatedObjects[idx].expansionStreak = 0

                        } else if newRect.contains(oldRect) {
                            // new rect contains old -> consider expansion only after hysteresis
                            let growthRatio = oldArea > 0 ? (newArea / oldArea) : 1.0
                            if growthRatio > growthThreshold {
                                self.aggregatedObjects[idx].expansionStreak += 1
                            } else {
                                self.aggregatedObjects[idx].expansionStreak = 0
                            }

                            if self.aggregatedObjects[idx].expansionStreak >= self.expansionHysteresis {
                                // apply expansion (smoothed) and reset streak
                                self.aggregatedObjects[idx].rect = smoothedRect(old: oldRect, new: newRect)
                                self.aggregatedObjects[idx].expansionStreak = 0
                                self.aggregatedObjects[idx].className = object.className
                            }

                            self.aggregatedObjects[idx].unseenFrames = 0
                            self.aggregatedObjects[idx].confidence = max(self.aggregatedObjects[idx].confidence, object.confidence)
                        } else {
                            // Overlapping -> consider union expansion with hysteresis
                            let unionRect = oldRect.union(newRect)
                            let unionArea = area(unionRect)
                            let unionRatio = oldArea > 0 ? (unionArea / oldArea) : 1.0

                            if unionRatio > growthThreshold {
                                self.aggregatedObjects[idx].expansionStreak += 1
                            } else {
                                self.aggregatedObjects[idx].expansionStreak = 0
                            }

                            if self.aggregatedObjects[idx].expansionStreak >= self.expansionHysteresis {
                                self.aggregatedObjects[idx].rect = smoothedRect(old: oldRect, new: unionRect)
                                self.aggregatedObjects[idx].expansionStreak = 0
                            }

                            self.aggregatedObjects[idx].unseenFrames = 0
                            self.aggregatedObjects[idx].confidence = max(self.aggregatedObjects[idx].confidence, object.confidence)
                        }
                    } else {
                        // No match -> create a new aggregated object
                        let agg = AggregatedObject(id: UUID().uuidString, rect: newRect, className: object.className, confidence: object.confidence, unseenFrames: 0, expansionStreak: 0)
                        self.aggregatedObjects.append(agg)
                    }
                }

                // Remove stale aggregated objects
                self.aggregatedObjects.removeAll { $0.unseenFrames > self.aggregationWindow }

                // Forward aggregated objects to presenter for drawing/interaction
                self.presenter.update(aggregatedObjects: self.aggregatedObjects)
            }
        }
    }


    @objc private func didReceiveLongPress(_ gesture: UILongPressGestureRecognizer) {
        if(!isRunning){
            return
        }
        let point = gesture.location(in: view)

        // Check the state of the gesture
        if gesture.state == .began {
            presenter.handleTouchBegan(at: point)
        } else if gesture.state == .ended {
            presenter.handleTouchEnded()
        }
    }

    @objc private func presenterModeChanged(_ sender: UISegmentedControl) {

        if(isRunning){
            // Clear previous presenter's UI
            manager!.stop()
            presenter.clear()
            manager!.start()
        }

        if sender.selectedSegmentIndex == 0 {
            // All
            presenter = ContinuousPresenter(overlayLayer: detectedObjectsLayer)
        } else {
            // Tap
            presenter = TapSelectPresenter(overlayLayer: detectedObjectsLayer)
        }
        
        if(isRunning){
            // Refresh presenter with current aggregation state immediately
            presenter.update(aggregatedObjects: aggregatedObjects)
        }
    }

}
