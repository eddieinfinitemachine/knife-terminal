import Foundation

// Where tabs meet folder trust (FolderTrust.swift): a tab about to start claude settles its folder
// before the command is typed, and every shell is followed as it moves, so `cd x`, then `claude`,
// starts without the prompt too.

extension TrustKeeper {
    static let shared = TrustKeeper(claudeJSON: NSHomeDirectory() + "/.claude.json",
                                    configPath: NSHomeDirectory() + "/.knife/config.json",
                                    knownCheckouts: { Projects.list().map(\.path) })
}

@MainActor
enum ShellFollower {
    private static var pending: Set<Int> = []

    /// Output landed in a tab (a prompt redrawn after `cd`, among much else): a moment later, settle
    /// the folder its shell is in. A burst of output is one look, and a folder already settled this
    /// run is a set lookup on the trust queue.
    static func outputLanded(in tab: TabModel) {
        guard pending.insert(tab.id).inserted else { return }
        let id = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak tab] in
            pending.remove(id)
            guard let pid = tab?.shellPid, pid > 0 else { return }
            // off the main thread: cwdOf falls back to lsof when the kernel won't say
            DispatchQueue.global(qos: .utility).async {
                if let cwd = TabModel.cwdOf(pid: pid) { TrustKeeper.shared.settle(cwd) }
            }
        }
    }
}
