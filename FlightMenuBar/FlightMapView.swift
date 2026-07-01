import SwiftUI
import MapKit
import CoreLocation

struct FlightMapView: View {
    let departure: CLLocationCoordinate2D
    let arrival: CLLocationCoordinate2D
    let position: FlightPosition?

    // .automatic fits the full route on first render; user pan/zoom preserved via @State
    @State private var camera: MapCameraPosition = .automatic

    // MapStyle.standard automatically switches to dark map tiles in dark mode (macOS 14+) —
    // no explicit style-switching needed. We use colorScheme only for overlay/line opacities.
    @Environment(\.colorScheme) private var colorScheme

    private var planeCoord: CLLocationCoordinate2D? {
        guard let p = position, !p.onGround else { return nil }
        return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
    }

    private var isAirborne: Bool { planeCoord != nil }

    // Compute compass bearing from 'from' to 'to' (0=N, 90=E, 180=S, 270=W)
    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude  * .pi / 180
        let lat2 = b.latitude  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // Heading derived from actual coordinates rather than OpenSky true_track (often null/stale)
    private var planeHeading: Double {
        guard let coord = planeCoord else { return 90 }
        return bearing(from: departure, to: coord)
    }

    // Dark map tiles absorb contrast, so bump opacity to compensate
    private var routeOpacity: Double {
        isAirborne
            ? (colorScheme == .dark ? 0.80 : 0.65)
            : (colorScheme == .dark ? 0.45 : 0.30)
    }

    // Border needs to be a touch more visible on dark glass
    private var borderOpacity: Double { colorScheme == .dark ? 0.14 : 0.07 }

    var body: some View {
        Map(position: $camera) {
            // Great-circle route — dimmer when no live position; opacity adapts to dark mode
            MapPolyline(coordinates: routeCoordinates())
                .stroke(Color.accentColor.opacity(routeOpacity), lineWidth: 2)

            // Departure marker — hollow ring
            Annotation("", coordinate: departure, anchor: .center) {
                departureDot
            }

            // Arrival marker — filled dot
            Annotation("", coordinate: arrival, anchor: .center) {
                arrivalDot
            }

            // Airplane (only when airborne); heading computed from actual coords
            if let coord = planeCoord {
                Annotation("", coordinate: coord, anchor: .center) {
                    planeIcon(heading: planeHeading)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if !isAirborne {
                Text("Position unavailable")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(7)
            }
        }
    }

    // MARK: - Annotation views

    // Departure: hollow ring (open circle = origin)
    private var departureDot: some View {
        Circle()
            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
            .background(Circle().fill(.white))
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    // Arrival: solid filled dot (destination)
    private var arrivalDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    // airplane SF Symbol faces right (East = 90°), so rotate by (heading - 90)
    private func planeIcon(heading: Double) -> some View {
        Image(systemName: "airplane")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Color.accentColor, in: Circle())
            .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1)
            .rotationEffect(.degrees(heading - 90))
    }

    // MARK: - Great-circle interpolation

    private func routeCoordinates() -> [CLLocationCoordinate2D] {
        let r = Double.pi / 180
        let φ1 = departure.latitude  * r,  λ1 = departure.longitude * r
        let φ2 = arrival.latitude    * r,  λ2 = arrival.longitude   * r

        let cosD = sin(φ1)*sin(φ2) + cos(φ1)*cos(φ2)*cos(λ2 - λ1)
        let d = acos(max(-1, min(1, cosD)))
        guard d > 0.001 else { return [departure, arrival] }

        return (0...60).map { i in
            let f  = Double(i) / 60
            let A  = sin((1 - f) * d) / sin(d)
            let B  = sin(f * d)       / sin(d)
            let x  = A*cos(φ1)*cos(λ1) + B*cos(φ2)*cos(λ2)
            let y  = A*cos(φ1)*sin(λ1) + B*cos(φ2)*sin(λ2)
            let z  = A*sin(φ1)          + B*sin(φ2)
            return CLLocationCoordinate2D(
                latitude:  atan2(z, sqrt(x*x + y*y)) / r,
                longitude: atan2(y, x) / r
            )
        }
    }
}
