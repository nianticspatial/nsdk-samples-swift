import UIKit
import ARKit
import SwiftyNsdk
import RealityKit

// TODO: data we need to include to set up the card view
class SavedMapCardView: UIView {
    var fileName: String?
    var image: String?
}

class MappingViewController: BaseARViewController, UITextFieldDelegate {
    private var deviceMappingManager: DeviceMappingManager?
    private var vpsManager: VpsManager?
    private var retryHelper: AuthRetryHelper!
    private var mappingButton: UIButton?
    private var saveButton: UIButton?
    private var loadButton: UIButton?
    private var scrollView: UIScrollView = UIScrollView()
    private var stackView: UIStackView = UIStackView()
    private var hasMappingStarted = false
    private var rootAnchorBase64: String?
    private var mapsPendingVisualization: [NsdkBuffer] = []
    private var extractedMetadata: [MapMetadata] = [] // Previously extracted metadata
    private var trackedAnchorId: NsdkVpsAnchorId?
    private var visualizedEntities: [Entity] = []
    private var mapAnchorEntity: AnchorEntity?
    private var cachedPointMesh: MeshResource?
    private var cachedPointMaterial: UnlitMaterial?
    /// Maximum number of point entities to show at once. Tune this for performance vs fidelity.
    private let maxDisplayedPoints: Int = 3000

    // For saving map names, allow alphanumeric characters as well as hyphens/underscores/periods
    private var fileNameAllowedCharacters: CharacterSet = {
            var set = CharacterSet.alphanumerics
            set.insert(charactersIn: "-_.")
            return set
        }()

    private func getAppSupportDirectory() throws -> URL {
        let fileManager = FileManager.default

        // 1. Get the base Application Support URL
        let baseAppSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true // This creates the base Application Support folder if it doesn't exist
        )

        // 2. Create an app-specific subdirectory (best practice)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.nianticspatial.nsdk-swift"
        let appSpecificURL = baseAppSupportURL.appendingPathComponent(bundleID)

        // 3. Ensure the app-specific directory exists
        if !fileManager.fileExists(atPath: appSpecificURL.path) {
            try fileManager.createDirectory(at: appSpecificURL, withIntermediateDirectories: true, attributes: nil)
        }

        return appSpecificURL
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if deviceMappingManager == nil {
            deviceMappingManager = DeviceMappingManager(nsdk: nsdkManager!.session)

            // Setup callback for map updates
            deviceMappingManager!.onMapUpdate = { [weak self] mapBuffer in
                self?.handleMapUpdate(mapBuffer: mapBuffer)
            }
        }

        // Initialize VpsManager with device mapping enabled
        if vpsManager == nil {
            vpsManager = VpsManager(
                nsdk: nsdkManager!.session,
                arSession: self.arView.session,
                deviceMapEnabled: true
            )
        }

        retryHelper = AuthRetryHelper(session: nsdkManager!.session)
        checkSavedMapsAvailable()
    }

    override func setupUI() {
        super.setupUI()

        self.title = "Device Mapping"
        helpLabel.text = "Device Mapping Sample Help\n\nThis sample lets you anchor content to the world by scanning the local area and saving a device map. These maps are saved to the device and can be shared to others.\n\n TO USE:\nPress \"Start Mapping\" to begin scanning the area around you. Once you're done press \"Stop Mapping\" to finalize the map.\nOnce the map creation is complete, press \"Save Map\" to save the file.\n\nTo view existing maps, press \"Load Map\" to view the list of maps saved on the device and select one to localize to."

        self.mappingButton = addButton(buttonTitle: "Start Mapping", onClickAction: #selector(handleToggleMappingTap))
        self.saveButton = addButton(buttonTitle: "Save Map", onClickAction: #selector(handleSaveButtonTap), xAnchor: view.safeAreaLayoutGuide.leadingAnchor, xOffset: 140, yAnchor: sampleInfoLabel.topAnchor, yOffset: -20 )
        saveButton?.backgroundColor = .systemGreen
        saveButton?.isHidden = true

        self.loadButton = addButton(buttonTitle: "Load Map", onClickAction: #selector(handleLoadButtonTap), xAnchor: view.safeAreaLayoutGuide.leadingAnchor, xOffset: 140, yAnchor: sampleInfoLabel.topAnchor, yOffset: -20 )
        loadButton?.backgroundColor = .systemPurple

        setupScrollView()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        view.addSubview(scrollView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.alignment = .fill
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: sampleInfoLabel.topAnchor, constant: -20),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func listSavedMaps() -> [String] {
        do {
            // Call with nil to get the base directory for saves
            let directoryURL = try getAppSupportDirectory()

            // Get all URLs in the directory, skipping hidden files
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            // Filter for files with the expected ".sav" extension and return just the names
            let fileNames = fileURLs
                .filter { $0.pathExtension == "map" }
                .map { $0.lastPathComponent }

            return fileNames

        } catch {
            print("Error listing saved maps: \(error.localizedDescription)")
            return []
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        deviceMappingManager?.stop()
        vpsManager?.stop()
    }

    private func checkSavedMapsAvailable() {
        // Load button should never appear once mapping has started
        if hasMappingStarted {
            loadButton?.isHidden = true
            return
        }

        let fileList = listSavedMaps()

        loadButton?.isHidden = fileList.isEmpty
    }

    private func handleMapUpdate(mapBuffer: NsdkBuffer) {
        print("Received map update with \(mapBuffer.dataSize) bytes")

        // Check if we need to get the root anchor
        if rootAnchorBase64 == nil {
            if let anchor = deviceMappingManager!.createRootAnchor() {
                rootAnchorBase64 = anchor
                print("Got root anchor during mapping")

                // Start VPS Manager and track anchor with callback. (we skip auth here since device mapping works locally)
                Task { @MainActor in
                    do {
                        vpsManager?.start()
                        let success = vpsManager?.trackAnchor(anchorPayload: anchor) { [weak self] anchorId, transform in
                            self?.handleAnchorUpdate(anchorId: anchorId, transform: transform)
                        }

                        if success == true {
                            print("Started tracking root anchor with VpsManager")
                        } else {
                            print("Failed to track root anchor")
                        }
                    } catch {
                        print("Failed to track root anchor: \(error)")
                    }
                }
            }
        }

        if rootAnchorBase64 != nil {
            mapsPendingVisualization.append(mapBuffer)
            print("Added chunk \(mapsPendingVisualization.count) for visualization")
        }
    }

    private func handleAnchorUpdate(anchorId: String, transform: simd_float4x4) {
        guard let rootAnchor = rootAnchorBase64 else {
            return
        }

        trackedAnchorId = anchorId

        // Update existing anchor entity transform if we have one
        if let existingAnchor = mapAnchorEntity {
            DispatchQueue.main.async {
                existingAnchor.transform = Transform(matrix: transform)
            }
        }

        // Extract metadata for new pending maps
        var newMetadata: [MapMetadata] = []

        for mapBuffer in mapsPendingVisualization {
            do {
                let mapMetadata = try deviceMappingManager!.extractMapMetadata(anchorPayloadBase64: rootAnchor, map: mapBuffer)
                guard let metadata = mapMetadata else {
                    print("Failed to extract map metadata for chunk. Check logs for error.")
                    continue
                }
                newMetadata.append(metadata)
                print("Extracted metadata for new chunk, points: \(metadata.pointsCount)")
            } catch {
                print("Failed to extract map metadata for chunk. Error: \(error)")
                continue
            }
        }

        // Only rebuild visualization if we have new metadata
        if !newMetadata.isEmpty {
            extractedMetadata.append(contentsOf: newMetadata)

            let totalPointsCount = extractedMetadata.reduce(0) { $0 + $1.pointsCount }
            if totalPointsCount > 0 {
                visualizeMapPoints(allMetadata: extractedMetadata, anchorTransform: transform)

                DispatchQueue.main.async {
                    self.updateInfoLabel(text: "Localized! Showing \(totalPointsCount) map points", color: .green)
                }
            }
        }

        newMetadata.removeAll()

        mapsPendingVisualization.removeAll()
    }

    private func visualizeMapPoints(allMetadata: [MapMetadata], anchorTransform: simd_float4x4) {
        // Clear previous visualization
        clearVisualization()

        // 1. Combine points and calculate total count
        var combinedPoints: [Float] = []
        for metadata in allMetadata {
            combinedPoints.append(contentsOf: metadata.points)
        }
        let totalPoints = combinedPoints.count / 3

        if totalPoints == 0 {
            return
        }

        // 2. Downsample
        let step = max(1, totalPoints / maxDisplayedPoints)

        // 3. Define the size and base geometry for a single cube
        let cubeHalfSize: Float = 0.0035

        // Base positions for a cube centered at (0, 0, 0)
        // Vertices [0] through [7]
        let basePositions: [SIMD3<Float>] = [
            // Front Face (Z = +halfSize)
            [-cubeHalfSize, -cubeHalfSize, cubeHalfSize], // 0: Bottom-Left-Front
            [ cubeHalfSize, -cubeHalfSize, cubeHalfSize], // 1: Bottom-Right-Front
            [ cubeHalfSize,  cubeHalfSize, cubeHalfSize], // 2: Top-Right-Front
            [-cubeHalfSize,  cubeHalfSize, cubeHalfSize], // 3: Top-Left-Front

            // Back Face (Z = -halfSize)
            [-cubeHalfSize, -cubeHalfSize, -cubeHalfSize], // 4: Bottom-Left-Back
            [ cubeHalfSize, -cubeHalfSize, -cubeHalfSize], // 5: Bottom-Right-Back
            [ cubeHalfSize,  cubeHalfSize, -cubeHalfSize], // 6: Top-Right-Back
            [-cubeHalfSize,  cubeHalfSize, -cubeHalfSize]  // 7: Top-Left-Back
        ]

        // Base indices for the 12 triangles (6 faces)
        let baseIndices: [UInt32] = [
            // Front Face: 0-1-2, 0-2-3
            0, 1, 2,  0, 2, 3,
            // Back Face: 5-4-7, 5-7-6
            5, 4, 7,  5, 7, 6,
            // Top Face: 3-2-6, 3-6-7
            3, 2, 6,  3, 6, 7,
            // Bottom Face: 4-5-1, 4-1-0
            4, 5, 1,  4, 1, 0,
            // Right Face: 1-5-6, 1-6-2
            1, 5, 6,  1, 6, 2,
            // Left Face: 4-0-3, 4-3-7
            4, 0, 3,  4, 3, 7
        ]

        // 4. Initialize combined buffers
        var combinedPositions: [SIMD3<Float>] = []
        var combinedIndices: [UInt32] = []

        let baseVertexCount = basePositions.count // 8
        var currentVertexOffset: UInt32 = 0

        // 5. Loop through map points, transform the base cube, and combine geometry
        let floatCount = combinedPoints.count
        var pointCount: UInt32 = 0
        var idx = 0
        while idx + 2 < floatCount && pointCount < maxDisplayedPoints {
            // Pick point center (translation vector)
            let center = SIMD3<Float>(combinedPoints[idx], combinedPoints[idx + 1], combinedPoints[idx + 2])

            // Translate the base cube's vertices to the map point location
            let translatedPositions = basePositions.map { $0 + center }
            combinedPositions.append(contentsOf: translatedPositions)

            // Offset and append the indices
            let offsetIndices = baseIndices.map { $0 + currentVertexOffset }
            combinedIndices.append(contentsOf: offsetIndices)

            // Update offsets for the next cube
            currentVertexOffset += UInt32(baseVertexCount)
            pointCount += 1
            idx += 3 * step
        }

        // 6. Create the final MeshDescriptor
        var meshDescriptor = MeshDescriptor()
        meshDescriptor.name = "mapCubes"
        meshDescriptor.positions = MeshBuffers.Positions(combinedPositions)
        meshDescriptor.primitives = .triangles(combinedIndices)

        // 7. Generate the single MeshResource from the descriptor
        guard let combinedMesh = try? MeshResource.generate(from: [meshDescriptor]) else {
            print("Failed to generate combined cube mesh.")
            return
        }

        // 8. Prepare Material (reusing cached material)
        if cachedPointMaterial == nil {
            cachedPointMaterial = UnlitMaterial(color: .init(red: 0.3, green: 0.8, blue: 0.0, alpha: 1.0))
        }

        // 9. Create the single ModelEntity
        let modelEntity = ModelEntity(mesh: combinedMesh, materials: [cachedPointMaterial!])

        // 10. Anchor to hold points
        let anchorEntity = AnchorEntity()
        anchorEntity.transform = Transform(matrix: anchorTransform)

        anchorEntity.addChild(modelEntity)

        // 11. Add to scene in a single main-thread batch
        DispatchQueue.main.async {
            self.arView.scene.addAnchor(anchorEntity)
            self.mapAnchorEntity = anchorEntity
            self.visualizedEntities.append(anchorEntity)
        }

        print("Added anchor node with a single ModelEntity and \(pointCount) cube-points to AR scene (downsampled from \(totalPoints))")
    }

    private func clearVisualization() {
        // Remove anchor parents from the scene
        for entity in visualizedEntities {
            DispatchQueue.main.async {
                // The single ModelEntity containing all points is a child of the AnchorEntity.
                // Removing the parent AnchorEntity automatically removes all its children.
                entity.removeFromParent()

                // If it's an AnchorEntity, also remove from scene's anchors
                if let anchorEntity = entity as? AnchorEntity {
                    self.arView.scene.removeAnchor(anchorEntity)
                }
            }
        }

        DispatchQueue.main.async {
            self.visualizedEntities.removeAll()
            self.updateInfoLabel(text: "")
        }
    }

    @objc private func handleToggleMappingTap() {
        if deviceMappingManager!.isMapping {
            deviceMappingManager!.stop()

            // Show save button if we have extracted metadata
            if !extractedMetadata.isEmpty {
                DispatchQueue.main.async {
                    self.saveButton?.isHidden = false
                }
            }

            DispatchQueue.main.async {
                self.updateInfoLabel(text: "")
            }
        } else {
            clearVisualization()
            resetAnchorTracking()

            deviceMappingManager!.start()

            hasMappingStarted = true
            loadButton?.isHidden = true

            DispatchQueue.main.async {
                self.updateInfoLabel(text: "Running Device Mapping", color: .white)
            }
        }

        mappingButton?.setTitle(deviceMappingManager!.isMapping ? "Stop Mapping" : "Start Mapping", for: .normal)
    }

    @objc private func handleSaveButtonTap() {
        guard let buffer =  deviceMappingManager!.getMapData() else {
            print("Failed to get map from storage")
            return
        }

        print("Retrieved complete map from storage, size: \(buffer.dataSize) bytes")

        // 1. Create the Alert Controller
        let alertController = UIAlertController(
            title: "Save Map",
            // Updated message to reflect the new allowed characters
            message: "Please enter a name for your save file.",
            preferredStyle: .alert
        )

        // 2. Add the Text Field for filename input
        alertController.addTextField { textField in
            textField.placeholder = "Enter filename..."
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            textField.text = "Map-\(formatter.string(from: Date()))"
        }

        // 3. Define the Cancel Action
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            print("Save operation cancelled by user.")
        }

        // 4. Define the Save Action
        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self,
                  let rawFileName = alertController.textFields?.first?.text else {
                return
            }

            // Trim leading/trailing whitespace and newlines
            let trimmedFileName = rawFileName.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check 1: Ensure filename is not empty
            guard !trimmedFileName.isEmpty else {
                //self.showErrorAlert(title: "Error", message: "Filename cannot be empty.")
                return
            }

            // Check 2: Enforce the custom set of allowed characters
            // We check if the trimmed string contains any characters *not* in the custom allowed set.
            if trimmedFileName.rangeOfCharacter(from: self.fileNameAllowedCharacters.inverted) != nil {
                // Updated error message to match the allowed characters
                //self.showErrorAlert(title: "Invalid Filename", message: "The filename must contain only letters, numbers, hyphens, underscores, and periods.")
                return
            }

            // If validation passes, call the file saving helper function
            self.saveMapToDisk(buffer: buffer, fileName: trimmedFileName)
        }

        // Disable the save button initially if the text field is empty
        if let text = alertController.textFields?.first?.text {
            saveAction.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // Add action handlers to the controller
        alertController.addAction(cancelAction)
        alertController.addAction(saveAction)

        // Observe changes in the text field to enable/disable the Save button
        NotificationCenter.default.addObserver(forName: UITextField.textDidChangeNotification, object: alertController.textFields?.first, queue: .main) { notification in
            if let textField = notification.object as? UITextField,
               let text = textField.text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saveAction.isEnabled = true
            } else {
                saveAction.isEnabled = false
            }
        }

        // 5. Present the Alert Controller
        self.present(alertController, animated: true)
    }

    @objc private func handleLoadButtonTap() {
        // Clear existing cards
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Get list of saved maps and their associated hint images
        let fileList = listSavedMaps()

        for mapFileName in fileList {
            let card = createMapSaveCard(fileName: mapFileName)
            stackView.addArrangedSubview(card)
        }

        scrollView.isHidden = false
        updateInfoLabel(text: "Found \(fileList.count) map(s)")
    }

    private func loadMapFromDisk(fileName: String) {
        do {
            scrollView.isHidden = true

            let finalFileName = fileName.hasSuffix(".map") ? fileName : "\(fileName).map"
            let directoryURL = try getAppSupportDirectory()
            let fileURL = directoryURL.appendingPathComponent(finalFileName)


            let mapData = try Data(contentsOf: fileURL)
            print("Read map data:" , mapData.count)
            let nsdkBuffer = NsdkBuffer(data: mapData)
            do {
                try deviceMappingManager!.addMap(dataBuffer: nsdkBuffer)
                loadButton?.isHidden = true
                print("Map added to map storage successfully")

                guard let anchor = deviceMappingManager!.createRootAnchor() else {
                    print("Failed to get root anchor for loaded map.")
                    return
                }

                // Start VPS Manager and track anchor with callback (we skip auth here since device mapping works locally)
                Task { @MainActor in
                    do {
                        vpsManager?.start()
                        let success = vpsManager?.trackAnchor(anchorPayload: anchor) { [weak self] anchorId, transform in
                            self?.handleAnchorUpdate(anchorId: anchorId, transform: transform)
                        }

                        if success == true {
                            self.rootAnchorBase64 = anchor
                            self.mapsPendingVisualization = [nsdkBuffer]
                            print("Started tracking loaded map anchor")

                            DispatchQueue.main.async {
                                self.updateInfoLabel(text: "Tracking anchor for localization...", color: .orange)
                            }
                        } else {
                            print("Failed to track root anchor")
                        }
                    } catch {
                        print("Failed to track root anchor: \(error)")
                    }
                }
            } catch {
                print("Failed to add map to storage: \(error)")
            }
        } catch {
            print("Failed to load map from disk: \(error)")
        }
    }

    private func saveMapToDisk(buffer: NsdkBuffer, fileName: String) {
        let mapData = Data(bytes: buffer.data, count: Int(buffer.dataSize))

        let finalFileName = fileName.hasSuffix(".map") ? fileName : "\(fileName).map"

        do {
            // Get the Application Support directory URL (no subdirectory for saves)
            let directoryURL = try getAppSupportDirectory()

            // Append the filename to get the final file path
            let fileURL = directoryURL.appendingPathComponent(finalFileName)

            try mapData.write(to: fileURL)
            print("Map saved successfully to: \(fileURL.path)")

            takeScreenshotAndSave(fileName: fileName)

            DispatchQueue.main.async {
                self.saveButton?.isHidden = true
                self.loadButton?.isHidden = false
                self.updateInfoLabel(text: "Map saved successfully", color: .green)
            }

        } catch {
            print("Failed to save map: \(error)")
        }
    }

    private func takeScreenshot() -> UIImage? {
        let maxScreenshotHeight: CGFloat = 320.0

        // Calculate the scaling factor to ensure height is at most maxScreenshotHeight
        var targetSize = view.bounds.size
        if view.bounds.height > maxScreenshotHeight {
            let scaleFactor = maxScreenshotHeight / view.bounds.height
            targetSize.width *= scaleFactor
            targetSize.height *= scaleFactor
        }

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let image = renderer.image { context in
            // Render the view hierarchy into the image context
            // The `drawHierarchy` method handles scaling content to the renderer's size
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return image
    }

    /**
     * Takes a screenshot, generates a unique filename, and saves the image as a PNG file
     * inside the "Screenshots" subdirectory of Application Support.
     */
    private func takeScreenshotAndSave(fileName: String) {
        guard let screenshotImage = takeScreenshot() else {
            print("Screenshot Failed, Could not capture the screen content.")
            return
        }

        // Use PNG representation as it is lossless and commonly used for screenshots
        guard let imageData = screenshotImage.pngData() else {
            print("Encoding Failed, Could not convert image to PNG data.")
            return
        }

        let finalFileName = "\(fileName).png"

        do {
            // Get the Application Support directory URL for screenshots
            let directoryURL = try getAppSupportDirectory()
            let fileURL = directoryURL.appendingPathComponent(finalFileName)

            // Write the PNG data to the file
            try imageData.write(to: fileURL)

            print("Successfully saved screenshot to: \(fileURL.path)")

        } catch {
            print("Failed to save screenshot: \(error.localizedDescription)")
        }
    }

    private func resetAnchorTracking() {
        trackedAnchorId = nil
        rootAnchorBase64 = nil
        mapsPendingVisualization.removeAll()
        extractedMetadata.removeAll()
        vpsManager?.stop()
        DispatchQueue.main.async {
            self.updateInfoLabel(text: "")
        }
    }

    private func createMapSaveCard(fileName: String) -> UIView {
        print("createMapSaveCard for \(fileName)")

        let cardView = SavedMapCardView()
        cardView.backgroundColor = UIColor.systemBackground
        cardView.layer.cornerRadius = 12
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOffset = CGSize(width: 0, height: 2)
        cardView.layer.shadowRadius = 4
        cardView.layer.shadowOpacity = 0.1

        // Make card tappable
        cardView.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(cardTapped(_:)))
        cardView.addGestureRecognizer(tapGesture)

        // Store the contents
        cardView.fileName = fileName

        let nameLabel = UILabel()
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 0
        nameLabel.text = fileName

        let hintImageView = UIImageView()
        hintImageView.contentMode = .scaleAspectFit
        hintImageView.layer.cornerRadius = 8
        hintImageView.clipsToBounds = true
        hintImageView.backgroundColor = .systemGray6
        hintImageView.tag = 101 //View Identifier.

        loadImage(imageView: hintImageView, fileName: fileName)

        // Layout
        [nameLabel, hintImageView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: hintImageView.leadingAnchor, constant: -12),

            hintImageView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            hintImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            hintImageView.widthAnchor.constraint(equalToConstant: 40),
            hintImageView.heightAnchor.constraint(equalToConstant: 80),
            hintImageView.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -16)
        ])

        return cardView
    }

    func loadImage(imageView : UIImageView, fileName: String) {
        // Ensure the filename has the correct extension for the load operation
        var processedFileName = fileName

        // 1. Check for and replace .map extension if it exists
        if processedFileName.lowercased().hasSuffix(".map") {
            // Remove the .sav extension
            processedFileName = String(processedFileName.dropLast(".map".count))
        }

        // 2. Ensure the filename has the correct .png extension for image loading
        let finalFileName = processedFileName.hasSuffix(".png") ? processedFileName : "\(processedFileName).png"

        do {
            let directoryURL = try getAppSupportDirectory()
            let fileURL = directoryURL.appendingPathComponent(finalFileName)

            // 1. Check if file exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("Load Failed, File not found at path: \(fileURL).")
                // Clear the image view if file not found
                imageView.image = nil
                return
            }

            // 2. Read the image data
            let imageData = try Data(contentsOf: fileURL)

            // 3. Create the image
            guard let image = UIImage(data: imageData) else {
                print("Load Failed, Could not convert file data to image format.")
                imageView.image = nil
                return
            }

            // 4. Assign the image
            imageView.image = image
            print("Successfully loaded image: \(finalFileName)")

        } catch {
            print("Failed to load image: \(error.localizedDescription)")
            imageView.image = nil
        }
    }

    @objc private func cardTapped(_ gesture: UITapGestureRecognizer) {
        guard let cardView = gesture.view as? SavedMapCardView,
              let fileName = cardView.fileName else { return }

        // Load map at filename
        loadMapFromDisk(fileName: fileName)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder() // Dismiss the keyboard
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if let enteredText = textField.text {
            print("User entered: \(enteredText)")
        }
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // If the replacementString is empty, it means the user is deleting characters, which is always allowed.
        guard !string.isEmpty else { return true }

        // Create a CharacterSet containing only alphanumeric characters.
        let allowedCharacters = CharacterSet.alphanumerics

        // Check if all characters in the replacementString are alphanumeric.
        // If not, filter them out.
        let filteredString = string.components(separatedBy: allowedCharacters.inverted).joined()

        // If the filtered string is different from the original string,
        // it means non-alphanumeric characters were present.
        // Only allow the change if the filtered string is identical to the original,
        // effectively preventing non-alphanumeric input.
        return filteredString == string
    }
}
