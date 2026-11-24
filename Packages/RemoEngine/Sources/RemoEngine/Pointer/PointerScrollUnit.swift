//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

/// What one `RemoteScreenClient.scrollPointer` delta counts in.
public enum PointerScrollUnit: UInt8, Sendable {
    /// Whole or fractional lines of content.
    case line = 1
    /// Points on the remote display.
    case pixel

    /// The largest magnitude one scroll message may carry on the wire.
    var wireLimit: Int32 { self == .line ? 100 : 10_000 }
}
