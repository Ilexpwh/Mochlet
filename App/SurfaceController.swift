import SwiftUI
import AppKit

private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class SurfaceController: NSObject {
    let model: AppModel
    private let statusItem: NSStatusItem
    private var workspace: NSWindow?
    private let panel: NSPanel
    private var monitor: Any?
    init(model: AppModel) {
        self.model=model
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        panel=CompanionPanel(contentRect:.init(x:0,y:0,width:400,height:500),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        statusItem.button?.image=NSImage(systemSymbolName:"drop.fill",accessibilityDescription:"Open Mochlet")
        statusItem.button?.target=self;statusItem.button?.action=#selector(togglePanel)
        statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        panel.level = .floating;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isMovableByWindowBackground=false;panel.hidesOnDeactivate=false
        panel.contentView=NSHostingView(rootView:CompanionView(model:model,compact:true).background(.regularMaterial,in:RoundedRectangle(cornerRadius:22)).preferredColorScheme(.dark))
        NotificationCenter.default.addObserver(self,selector:#selector(reposition),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                if event.keyCode == 53, self?.panel.isKeyWindow == true { self?.panel.orderOut(nil);return true }
                if event.modifierFlags.contains([.command,.shift]),event.keyCode == 49 { self?.togglePanel();return true }
                return false
            }
            return handled ? nil : event
        }
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu()
            menu.addItem(withTitle:"Open workspace",action:#selector(showWorkspace),keyEquivalent:"").target=self
            menu.addItem(.separator());menu.addItem(withTitle:"Quit Mochlet",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            statusItem.menu=menu;statusItem.button?.performClick(nil);statusItem.menu=nil;return
        }
        if panel.isVisible { panel.orderOut(nil) }
        else { reposition();panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    }
    @objc func reposition() {
        guard let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main else { return }
        let top=screen.frame.maxY-max(screen.safeAreaInsets.top,screen.frame.maxY-screen.visibleFrame.maxY)
        panel.setFrameOrigin(.init(x:screen.frame.midX-panel.frame.width/2,y:top-panel.frame.height-8))
    }
    @objc func showWorkspace() {
        if workspace == nil {
            let w=NSWindow(contentRect:.init(x:0,y:0,width:1000,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            w.title="Mochlet";w.minSize = .init(width:760,height:560);w.isReleasedWhenClosed=false
            w.titlebarAppearsTransparent=true
            w.contentView=NSHostingView(rootView:WorkspaceView(model:model));w.center();workspace=w
        }
        workspace?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
}
