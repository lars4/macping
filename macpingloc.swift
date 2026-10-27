// MacPingLoc - one-shot CoreLocation helper for macping.
//
// Writes "<lat> <lon> <accuracy_m>" or "ERR <reason>" to the file given as
// the first argument (default: /tmp/macping-loc.txt), then exits.

import AppKit
import CoreLocation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/macping-loc.txt"

func finish(_ s: String) -> Never {
    try? s.write(toFile: outPath, atomically: true, encoding: .utf8)
    exit(0)
}

final class Locator: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var best: CLLocation?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
        // Give up after 25 s and report the best fix so far.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [self] in
            if let b = best { report(b) }
            else if manager.authorizationStatus == .notDetermined { finish("ERR not_authorized") }
            else { finish("ERR timeout") }
        }
    }

    func report(_ l: CLLocation) -> Never {
        finish(String(format: "%.6f %.6f %.0f",
                      l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy))
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .denied || m.authorizationStatus == .restricted {
            finish("ERR denied")
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        for l in locs where l.horizontalAccuracy >= 0 {
            if best == nil || l.horizontalAccuracy < best!.horizontalAccuracy { best = l }
        }
        if let b = best, b.horizontalAccuracy <= 100 { report(b) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { finish("ERR denied") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let locator = Locator()
locator.start()
app.run()
