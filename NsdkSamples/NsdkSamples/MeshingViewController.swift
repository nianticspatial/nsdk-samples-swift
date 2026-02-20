import UIKit
import ARKit
import SwiftyNsdk

class MeshingViewController: BaseARViewController {
    private var nsdkMeshing: MeshingManager?
    private var isMeshing = false
    private var timer: Timer?
    private var meshingButton: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func setupUI() {
        super.setupUI()

        self.title = "Meshing"
        helpLabel.text = "Meshing Sample Help\n\nThis sample creates a 3d mesh of the environment in front of your device camera.\n\n TO USE: \n Press the \"Start Meshing\" button and move the camera around. A mesh is dynamically created and rendered. this Mesh is not persistent and to restart press the \"Stop Meshing\" button, and the process will restart."

        updateInfoLabel(text: "Ready to start meshing")
        self.meshingButton = addButton(buttonTitle: "Start Meshing", onClickAction: #selector(handleToggleMeshingTap))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopMeshing()
    }

    private func startMeshing() {
        meshingButton?.setTitle("Stop Meshing", for: .normal)
        nsdkMeshing?.start()
        // Start polling for mesh updates
        isMeshing = true
        updateInfoLabel(text: "Meshing started")
    }

    private func stopMeshing() {
        timer?.invalidate()
        timer = nil
        isMeshing = false
        nsdkMeshing?.stop()
        meshingButton?.setTitle("Start Meshing", for: .normal)
        updateInfoLabel(text: "Meshing stopped")
    }

    @objc private func handleToggleMeshingTap() {
        if nsdkMeshing == nil {
            nsdkMeshing = MeshingManager(nsdk: nsdkManager!.session, arView: arView, infoLabel: sampleInfoLabel)
        }

        if isMeshing {
            stopMeshing()
        } else {
            startMeshing()
        }
    }

    // NSDK update loop
    override func session(_ session: ARSession, didUpdate frame: ARFrame) {
        super.session(session, didUpdate: frame)

        if (isMeshing) {
            // Checks if there is new mesh data available and renders it in the sceneView
            nsdkMeshing?.updateMesh()
        }
    }
}
