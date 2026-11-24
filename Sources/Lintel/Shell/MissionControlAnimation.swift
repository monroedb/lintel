import LintelCore
import SwiftUI

extension MissionControlTiming {
    /// The tuck as a SwiftUI animation (a spring, so a quick reversal retargets smoothly).
    static var tuckAnimation: Animation {
        .spring(response: tuckResponse, dampingFraction: tuckDamping)
    }
}
