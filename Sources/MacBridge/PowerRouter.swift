import Foundation

enum PowerRouter {
    static func dispatch(path: String, args: [String: Any]) -> [String: Any]? {
        switch path {
        case "/automation/permissions": return PowerSupport.permissions(args)
        case "/mouse/position": return MouseModule.position(args: args)
        case "/mouse/move": return MouseModule.move(args: args)
        case "/mouse/click": return MouseModule.click(args: args)
        case "/mouse/drag": return MouseModule.drag(args: args)
        case "/mouse/scroll": return MouseModule.scroll(args: args)
        case "/screen/displays": return ScreenModule.displays(args: args)
        case "/screen/capture": return ScreenModule.capture(args: args)
        case "/ui/apps": return AccessibilityModule.apps(args: args)
        case "/ui/activate": return AccessibilityModule.activate(args: args)
        case "/ui/snapshot": return AccessibilityModule.snapshot(args: args)
        case "/ui/find": return AccessibilityModule.find(args: args)
        case "/ui/action": return AccessibilityModule.action(args: args)
        case "/whatsapp/status": return WhatsAppModule.status(args: args)
        case "/whatsapp/open": return WhatsAppModule.open(args: args)
        case "/whatsapp/open-chat": return WhatsAppModule.open(args: args, chat: true)
        case "/whatsapp/read": return WhatsAppModule.read(args: args)
        case "/whatsapp/search": return WhatsAppModule.search(args: args)
        case "/whatsapp/open-chat-by-name": return WhatsAppModule.openChatByName(args: args)
        case "/whatsapp/draft": return WhatsAppModule.draft(args: args)
        case "/whatsapp/send": return WhatsAppModule.send(args: args)
        case "/windows/list": return WindowsModule.list(args: args)
        case "/windows/focus": return WindowsModule.focus(args: args)
        case "/windows/set-frame": return WindowsModule.setFrame(args: args)
        case "/windows/arrange": return WindowsModule.arrange(args: args)
        case "/windows/minimize": return WindowsModule.minimize(args: args)
        case "/windows/close": return WindowsModule.close(args: args)
        case "/ocr/image": return OCRModule.image(args: args)
        case "/ocr/screen": return OCRModule.screen(args: args)
        case "/documents/pdf-info": return DocumentsModule.info(args: args)
        case "/documents/pdf-text": return DocumentsModule.text(args: args)
        case "/documents/create-pdf": return DocumentsModule.createPDF(args: args)
        case "/permissions/status": return PermissionStatusModule.status(args: args)
        default: return nil
        }
    }
}
