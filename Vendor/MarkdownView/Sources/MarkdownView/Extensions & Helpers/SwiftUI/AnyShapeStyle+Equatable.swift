import SwiftUI

@_documentation(visibility: internal)
extension AnyShapeStyle: @retroactive Equatable {
    @_spi(Internal)
    public static func == (lhs: AnyShapeStyle, rhs: AnyShapeStyle) -> Bool {
        // wooloo patch: compare boxed style identity conservatively, while both borrows
        // are alive. Returning either buffer lets its stack storage expire/reuse, making
        // different styles compare equal and suppressing environment changes.
        withUnsafeBytes(of: lhs) { old in
            withUnsafeBytes(of: rhs) { new in
                old.elementsEqual(new)
            }
        }
    }
}
