import Foundation
import Testing
@testable import MochletCore

@Suite struct ProjectsFileTests {
    @Test func roundTripKeepsFieldsAndIsStable() throws {
        let p = Project(slug: "mochlet", name: "Mochlet", aliases: ["slime", "史莱姆"], description: "notch slime", paths: ["/Users/me/slime-ai"],
                        repo: "git@github.com:Ilexpwh/Mochlet.git", defaultAgent: "claude", tags: ["swift"], createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        lastSessions: ["claude": "abc"])
        let file = ProjectsFile(projects: [p])
        let data = try file.encode()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"default\" : \"inbox\""))
        #expect(text.contains("\"last_sessions\""))
        #expect(text.contains("2023-11-14T22:13:20Z"))
        #expect(text.hasSuffix("\n"))
        let back = try ProjectsFile.decode(data)
        #expect(back == file)
        #expect(try back.encode() == data)
    }

    @Test func toleratesMinimalEntries() throws {
        let json = #"{"projects":[{"slug":"x","paths":["/tmp/x"]}]}"#
        let f = try ProjectsFile.decode(Data(json.utf8))
        #expect(f.version == 1)
        #expect(f.defaultProject == "inbox")
        #expect(f.projects[0].name == "x")
        #expect(f.projects[0].archived == false)
    }
}

@Suite struct SlugTests {
    @Test func asciiAndCJK() {
        #expect(Slug.make("Hello, World!") == "hello-world")
        #expect(Slug.make("  Mochlet v2 — notch  ") == "mochlet-v2-notch")
        #expect(Slug.make("史莱姆 项目") == "shi-lai-mu-xiang-mu")
        #expect(Slug.make("Crème Brûlée") == "creme-brulee")
        #expect(Slug.make("!!!").hasPrefix("untitled-"))
        #expect(Slug.make(String(repeating: "a", count: 100)).count == 60)
        #expect(Slug.unique("x", taken: ["x", "x-2"]) == "x-3")
    }
}

@Suite struct ProjectResolverTests {
    let projects = [
        Project(slug: "mochlet", name: "Mochlet", paths: ["~/slime-ai"]),
        Project(slug: "kit", name: "SlimeKit", paths: ["~/slime-ai/Packages/SlimeKit"]),
        Project(slug: "old", name: "Old", paths: ["~/old"], archived: true),
    ]

    @Test func longestRegisteredPathWins() {
        let home = NSHomeDirectory()
        let a = ProjectResolver.resolve(cwd: "\(home)/slime-ai/App", sessionRoot: nil, projects: projects)
        #expect(a.name == "Mochlet" && a.isRegistered)
        let b = ProjectResolver.resolve(cwd: "\(home)/slime-ai/Packages/SlimeKit/Sources", sessionRoot: nil, projects: projects)
        #expect(b.name == "SlimeKit")
        let c = ProjectResolver.resolve(cwd: "\(home)/old/x", sessionRoot: "\(home)/old", projects: projects)
        #expect(c.name == "old" && !c.isRegistered)
        let d = ProjectResolver.resolve(cwd: "/tmp/elsewhere/sub", sessionRoot: "/tmp/elsewhere", projects: projects, fallbackName: "elsewhere")
        #expect(d.path == "/tmp/elsewhere" && d.name == "elsewhere")
        #expect(ProjectResolver.project(containing: "\(home)/slime-ai/App", in: projects)?.slug == "mochlet")
    }
}

@Suite struct ProjectMatcherTests {
    let projects = [
        Project(slug: "mochlet", name: "Mochlet", aliases: ["slime", "史莱姆"], paths: ["/a"]),
        Project(slug: "notes-app", name: "Notes App", paths: ["/b"]),
        Project(slug: "nex", name: "Nex", paths: ["/c"]),
    ]

    @Test func exactPrefixAndFuzzy() {
        #expect(ProjectMatcher.match("mochlet", in: projects)?.slug == "mochlet")
        #expect(ProjectMatcher.match("史莱姆", in: projects)?.slug == "mochlet")
        #expect(ProjectMatcher.match("Notes", in: projects)?.slug == "notes-app")
        #expect(ProjectMatcher.match("mochlit", in: projects)?.slug == "mochlet")
        #expect(ProjectMatcher.match("n", in: projects) == nil)
        #expect(ProjectMatcher.match("zzz", in: projects) == nil)
    }
}

@Suite struct ProjectIntentParserTests {
    @Test func english() {
        #expect(ProjectIntentParser.parse("make ~/slime-ai a project called Mochlet") == .makeProject(path: NSHomeDirectory() + "/slime-ai", name: "Mochlet"))
        #expect(ProjectIntentParser.parse("add project /tmp/x") == .makeProject(path: "/tmp/x", name: nil))
        #expect(ProjectIntentParser.parse("clone https://github.com/a/b as bee") == .clone(url: "https://github.com/a/b", name: "bee"))
        #expect(ProjectIntentParser.parse("Work on Mochlet: fix the tests with codex") == .workOn(project: "Mochlet", task: "fix the tests", agent: "codex"))
        #expect(ProjectIntentParser.parse("work on nex: add a README") == .workOn(project: "nex", task: "add a README", agent: nil))
        #expect(ProjectIntentParser.parse("resume Mochlet") == .resume(project: "Mochlet", agent: nil))
        #expect(ProjectIntentParser.parse("resume mochlet with claude") == .resume(project: "mochlet", agent: "claude"))
        #expect(ProjectIntentParser.parse("open Mochlet in iTerm") == .open(project: "Mochlet", terminal: "iterm"))
        #expect(ProjectIntentParser.parse("open nex in VS Code") == .open(project: "nex", terminal: "vscode"))
        #expect(ProjectIntentParser.parse("list projects") == .listProjects)
        #expect(ProjectIntentParser.parse("what is the weather") == nil)
        #expect(ProjectIntentParser.parse("explain how work on this file: foo") == nil)
    }

    @Test func chinese() {
        #expect(ProjectIntentParser.parse("把 ~/slime-ai 设为项目，叫 史莱姆") == .makeProject(path: NSHomeDirectory() + "/slime-ai", name: "史莱姆"))
        #expect(ProjectIntentParser.parse("克隆 https://github.com/a/b 为 bee") == .clone(url: "https://github.com/a/b", name: "bee"))
        #expect(ProjectIntentParser.parse("在 Mochlet 上工作：修复测试，用 codex") == .workOn(project: "Mochlet", task: "修复测试", agent: "codex"))
        #expect(ProjectIntentParser.parse("继续 Mochlet") == .resume(project: "Mochlet", agent: nil))
        #expect(ProjectIntentParser.parse("打开 Mochlet 用 iterm") == .open(project: "Mochlet", terminal: "iterm"))
        #expect(ProjectIntentParser.parse("项目列表") == .listProjects)
    }
}

@Suite struct TerminalLaunchPlannerTests {
    @Test func agentCommandLines() {
        #expect(AgentLaunch(agent: .claude, task: "fix it's bug").commandLine == "claude 'fix it'\\''s bug'")
        #expect(AgentLaunch(agent: .claude, resume: "abc", model: "opus").commandLine == "claude --model 'opus' --resume 'abc'")
        #expect(AgentLaunch(agent: .codex, task: "hi").commandLine == "codex 'hi'")
        #expect(AgentLaunch(agent: .codex, resume: "t1").commandLine == "codex resume 't1'")
        #expect(AgentLaunch(agent: .gemini, task: "hi").commandLine == "gemini -i 'hi'")
        #expect(AgentLaunch(agent: .gemini, resume: "s1").commandLine == "gemini --resume 's1'")
    }

    @Test func perTerminalSteps() {
        let cmd = "claude 'hi'"
        let t = TerminalLaunchPlanner.plan(terminal: .terminal, cwd: "/Users/me/p", command: cmd, title: "p")
        guard case .appleScript(let src, let bundle) = t[0] else { Issue.record("expected AppleScript"); return }
        #expect(bundle == "com.apple.Terminal")
        #expect(src.contains("do script \"cd '/Users/me/p' && claude 'hi'\""))
        let i = TerminalLaunchPlanner.plan(terminal: .iterm, cwd: "/Users/me/p", command: cmd, title: "p")
        guard case .appleScript(let isrc, _) = i[0] else { Issue.record("expected AppleScript"); return }
        #expect(isrc.contains("create window with default profile") && isrc.contains("write text"))
        let w = TerminalLaunchPlanner.plan(terminal: .warp, cwd: "/Users/me/p", command: cmd, title: "p")
        #expect(w.count == 2)
        guard case .writeFile(let path, let yaml) = w[0], case .open(let args) = w[1] else { Issue.record("warp shape"); return }
        #expect(path.hasSuffix("mochlet-p.yaml") && yaml.contains("cwd: \"/Users/me/p\"") && args == ["warp://launch/mochlet-p"])
        let k = TerminalLaunchPlanner.plan(terminal: .kitty, cwd: "/Users/me/p", command: cmd, title: "p")
        guard case .command(let name, let kargs) = k[0] else { Issue.record("kitty shape"); return }
        #expect(name == "kitty" && kargs.contains("--directory") && kargs.last!.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
        let g = TerminalLaunchPlanner.plan(terminal: .ghostty, cwd: "/Users/me/p", command: cmd, title: "p")
        guard case .open(let gargs) = g[0] else { Issue.record("ghostty shape"); return }
        #expect(gargs.contains("--working-directory=/Users/me/p"))
    }
}

@Suite struct ProjectTrustTests {
    @Test func trustDefaultsToTrueAndRoundTripsFalse() throws {
        let legacy = Data(#"{"version":1,"projects":[{"slug":"a","name":"A","paths":["/tmp/a"]}]}"#.utf8)
        let f = try ProjectsFile.decode(legacy)
        #expect(f.projects[0].trusted == true)
        var clone = Project(slug: "c", name: "C", paths: ["/tmp/c"], trusted: false)
        clone.lastSessions["claude"] = "x"
        let encoded = try ProjectsFile(projects: [clone]).encode()
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"trusted\" : false"))
        #expect(try ProjectsFile.decode(encoded).projects[0].trusted == false)
    }
}
