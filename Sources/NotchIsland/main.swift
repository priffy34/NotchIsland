import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // без иконки в Dock

let controller = IslandController()
controller.start()

app.run()
