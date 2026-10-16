import AppKit
import CoreFoundation
import CoreGraphics
import BigWaterCore
@testable import BigWaterApp

@MainActor
func runPlacementChecks() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "BigWaterSessionChecks.Placement", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    let fallbackEntrance = ReminderEntrance(edge: .right, position: 0.37)
    try expect(OverlayControls.reminderEntrance(for: .random, randomEntrance: fallbackEntrance)
               == fallbackEntrance, "Random placement changed the supplied entrance")
    let cornerEntrances: [(ReminderPosition, ReminderEdge, Double)] = [
        (.topLeft, .top, 0), (.topRight, .top, 1),
        (.bottomLeft, .bottom, 0), (.bottomRight, .bottom, 1)
    ]
    for (position, edge, along) in cornerEntrances {
        try expect(OverlayControls.reminderEntrance(for: position, randomEntrance: fallbackEntrance)
                   == ReminderEntrance(edge: edge, position: along),
                   "\(position) did not map to its fixed entrance corner")
    }

    let visibleBounds = CGRect(x: 80, y: 38, width: 560, height: 318)
    let expectedOrigins: [ReminderPosition: CGPoint] = [
        .random: CGPoint(x: 346, y: 134),
        .topLeft: CGPoint(x: 98, y: 56),
        .topRight: CGPoint(x: 346, y: 56),
        .bottomLeft: CGPoint(x: 98, y: 134),
        .bottomRight: CGPoint(x: 346, y: 134)
    ]
    for position in ReminderPosition.allCases {
        let layout = OverlayControls.compactLayout(visibleBounds: visibleBounds, isPreview: false,
                                                   position: position)
        try expect(layout.card.origin == expectedOrigins[position]!,
                   "Compact card did not anchor at the \(position) corner")
        try expect(visibleBounds.contains(layout.card)
                   && layout.buttons.allSatisfy({ layout.card.contains($0.frame) }),
                   "Compact card or controls escaped Dock-offset visible bounds")
    }
    let defaultCompact = OverlayControls.compactLayout(visibleBounds: visibleBounds, isPreview: false)
    let randomCompact = OverlayControls.compactLayout(visibleBounds: visibleBounds, isPreview: false,
                                                      position: .random)
    try expect(defaultCompact.card == randomCompact.card
               && randomCompact.card.origin == expectedOrigins[.bottomRight]!,
               "Random placement changed the established compact-card default")

    let defaults = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
    try expect(defaults.placement == ReminderPlacement(),
               "Missing placement did not decode with default values")
    var preferences = AppPreferences()
    preferences.placement = ReminderPlacement(position: .topLeft, screen: .selected,
                                              displayID: "A0B1C2D3-1234-5678-9ABC-DEF012345678")
    let roundTrip = try JSONDecoder().decode(AppPreferences.self,
                                             from: JSONEncoder().encode(preferences))
    try expect(roundTrip.placement == preferences.placement,
               "Placement selection did not persist through AppPreferences")
    let unknownPlacement = try JSONDecoder().decode(
        AppPreferences.self,
        from: Data(#"{"placement":{"position":"future","screen":42,"displayID":false}}"#.utf8)
    )
    try expect(unknownPlacement.placement == ReminderPlacement(),
               "Unknown or mistyped placement values did not use defaults")

    guard let main = NSScreen.screens.first,
          let mainID = placementDisplayIdentifier(main) else {
        throw NSError(domain: "BigWaterSessionChecks.Placement", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "The current main display has no stable UUID"])
    }
    let displays = OverlayController.availableDisplays
    let primaryOverlay = OverlayController()
    defer { primaryOverlay.stop() }
    try expect(primaryOverlay.start(style: .compact,
                                    placement: ReminderPlacement(position: .topRight, screen: .main)),
               "Reminder could not start on the primary display")
    try expect(primaryOverlay.buttonPanels.first.map {
        main.visibleFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
    } == true, "Primary-display selection followed the focused window instead")
    guard let display = displays.first(where: { $0.id != mainID }) ?? displays.first,
          let selectedScreen = NSScreen.screens.first(where: {
              placementDisplayIdentifier($0) == display.id
          }) else {
        throw NSError(domain: "BigWaterSessionChecks.Placement", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "No UUID-addressable display is available"])
    }

    let selectedOverlay = OverlayController()
    defer { selectedOverlay.stop() }
    try expect(selectedOverlay.start(style: .compact,
                                     placement: ReminderPlacement(position: .topLeft,
                                                                  screen: .selected,
                                                                  displayID: display.id)),
               "Reminder could not start on a connected selected display")
    guard let selectedButton = selectedOverlay.buttonPanels.first else {
        throw NSError(domain: "BigWaterSessionChecks.Placement", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Selected-display reminder did not create its controls"])
    }
    try expect(selectedScreen.visibleFrame.contains(CGPoint(x: selectedButton.frame.midX,
                                                            y: selectedButton.frame.midY)),
               "Connected UUID selection placed the compact controls on another display")

    let missingOverlay = OverlayController()
    defer { missingOverlay.stop() }
    try expect(missingOverlay.start(style: .compact,
                                   placement: ReminderPlacement(position: .topLeft,
                                                                screen: .selected,
                                                                displayID: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
               "Reminder could not start when its saved display was disconnected")
    guard let fallbackButton = missingOverlay.buttonPanels.first else {
        throw NSError(domain: "BigWaterSessionChecks.Placement", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Fallback reminder did not create its controls"])
    }
    try expect(main.visibleFrame.contains(CGPoint(x: fallbackButton.frame.midX,
                                                  y: fallbackButton.frame.midY)),
               "Disconnected UUID selection did not fall back to the main display")
}

private func placementDisplayIdentifier(_ screen: NSScreen) -> String? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
    else { return nil }
    guard let value = CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) else { return nil }
    return value as String
}
