// Copyright 2026 Niantic Spatial.

import SwiftUI
import MapKit
import CoreLocation
import Observation

/// A tap-created AR anchor's position on the mini-map, mirroring the Kotlin sample. Plotted from
/// the anchor's VPS2 geolocation so its map dot can be compared against its AR cube's placement.
struct VPS2AnchorMapDot: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let color: Color
}

/// Observable data backing the VPS2 map overlay.
@Observable
final class VPS2MapData {
    var userCoordinate: CLLocationCoordinate2D?
    var userHeading: Double?
    var poiCoordinate: CLLocationCoordinate2D?
    var isVisible: Bool = false
    var placedMarkers: [VPS2PlacedMarker] = []
    var anchorDots: [VPS2AnchorMapDot] = []
    /// Whether tapping the map places a marker. Driven by the VPS2 tracking state.
    var isPlacementEnabled: Bool = false
}

/// Miniature map card for the VPS2 screen showing the user and POI locations.
/// Occupies `height` when visible and collapses to nothing when hidden; the
/// caller places it in the screen's bottom chrome stack.
struct VPS2MapView: View {

    var data: VPS2MapData
    var height: CGFloat
    var onTapCoordinate: (CLLocationCoordinate2D) -> Void = { _ in }

    /// Camera height until the user pinches to change it.
    private let defaultCameraDistanceMetres: CLLocationDistance = 200

    /// How far the device must move before the map recentres. The geolocation updates
    /// every frame, so without this the camera animates continuously on sensor noise.
    private let recentreThresholdMetres: CLLocationDistance = 1

    // MARK: - State

    /// `.automatic` frames the annotations until the first device geolocation arrives.
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var centredOn: CLLocationCoordinate2D?
    /// The zoom the user pinched to, carried across recentres.
    @State private var cameraDistance: CLLocationDistance?

    // MARK: - Body

    var body: some View {
        if data.isVisible {
            mapCard
        }
    }

    // MARK: - Map Card

    private var mapCard: some View {
        // MapReader supplies the screen-point to coordinate conversion. Panning stays off
        // so this view keeps sole control of the centre; the user controls only the zoom.
        // The placement tap is a SwiftUI gesture layered on top.
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: .zoom) {
                mapContent
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                cameraDistance = context.camera.distance
            }
            .onChange(of: CoordinateKey(data.userCoordinate)) { _, _ in
                recentreIfNeeded(on: data.userCoordinate)
            }
            .onTapGesture { point in
                guard
                    data.isPlacementEnabled,
                    let coordinate = proxy.convert(point, from: .local)
                else { return }
                onTapCoordinate(coordinate)
            }
        }
        .mapStyle(.standard)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.green, lineWidth: data.isPlacementEnabled ? 3 : 0)
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.3), radius: 4)
    }

    // MARK: - Camera

    /// `CLLocationCoordinate2D` is not `Equatable`, which `onChange(of:)` requires.
    private struct CoordinateKey: Equatable {
        let latitude: Double
        let longitude: Double

        init?(_ coordinate: CLLocationCoordinate2D?) {
            guard let coordinate else { return nil }
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        }
    }

    /// Keeps the device centred, ignoring sub-metre jitter.
    private func recentreIfNeeded(on coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }

        if let centredOn {
            let previous = CLLocation(latitude: centredOn.latitude, longitude: centredOn.longitude)
            let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard previous.distance(from: current) >= recentreThresholdMetres else { return }
        }

        centredOn = coordinate
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: coordinate,
                distance: cameraDistance ?? defaultCameraDistanceMetres
            )
        )
    }

    /// Split out of `mapCard` to keep the map builder's type inference cheap.
    @MapContentBuilder
    private var mapContent: some MapContent {
        if let coord = data.userCoordinate {
            Annotation("", coordinate: coord) {
                LocationIndicator(color: .blue, heading: data.userHeading)
            }
        }
        if let coord = data.poiCoordinate {
            Annotation("", coordinate: coord) {
                LocationIndicator(color: .red)
            }
        }
        ForEach(data.placedMarkers) { marker in
            Annotation("", coordinate: marker.coordinate) {
                LocationIndicator(color: Color(uiColor: marker.color))
            }
        }
        ForEach(data.anchorDots) { dot in
            Annotation("", coordinate: dot.coordinate) {
                LocationIndicator(color: dot.color)
            }
        }
    }
}

// MARK: - Location Indicator

/// A colored dot marking a coordinate, with an optional translucent cone
/// pointing in the supplied heading direction.
private struct LocationIndicator: View {
    var color: Color
    var heading: Double? = nil

    var body: some View {
        ZStack {
            if let heading {
                HeadingCone()
                    .fill(color.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(heading))
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
    }
}

/// Triangular cone pointing upward, used to indicate a heading direction.
private struct HeadingCone: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x - 12, y: center.y - 30))
        path.addLine(to: CGPoint(x: center.x + 12, y: center.y - 30))
        path.closeSubpath()
        return path
    }
}
