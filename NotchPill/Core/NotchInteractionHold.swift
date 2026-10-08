import Foundation

/// Independent holds prevent one menu ending from releasing another menu or
/// the deferred destination picker that is about to take over.
struct NotchInteractionHold {
    var manual = false
    private var menus = Set<ObjectIdentifier>()
    var isHeld: Bool { manual || !menus.isEmpty }

    mutating func begin(_ menu: AnyObject) { menus.insert(ObjectIdentifier(menu)) }
    mutating func end(_ menu: AnyObject) { menus.remove(ObjectIdentifier(menu)) }
}
