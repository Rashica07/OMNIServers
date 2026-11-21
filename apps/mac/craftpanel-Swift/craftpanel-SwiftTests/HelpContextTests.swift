import Testing
@testable import craftpanel_Swift

@Suite struct HelpContextTests {
    @Test func settingsAndOverviewWin() {
        #expect(HelpContext.topic(settings: true, overview: true, section: "network") == "diagnostics")
        #expect(HelpContext.topic(settings: false, overview: true, section: "network") == "overview")
    }
    @Test func serverTabsMapToTopics() {
        #expect(HelpContext.topic(settings: false, overview: false, section: "network") == "network")
        #expect(HelpContext.topic(settings: false, overview: false, section: "worlds") == "worlds")
        #expect(HelpContext.topic(settings: false, overview: false, section: "mods") == "mods")
        #expect(HelpContext.topic(settings: false, overview: false, section: "addons") == "mods")
        #expect(HelpContext.topic(settings: false, overview: false, section: "console") == "start")
        #expect(HelpContext.topic(settings: false, overview: false, section: nil) == "start")
    }
}
