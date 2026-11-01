import Foundation

struct GitHubCredentials: Sendable {
    let token: String
    static func load(executable: String) async throws -> GitHubCredentials {
        let result = try await CommandProcess().run(executable: executable, arguments: ["auth", "token", "--hostname", "github.com"], environment: ["GH_PROMPT_DISABLED": "1"])
        let token = String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !token.isEmpty, token.utf8.count < 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw MochletError.message("Could not obtain the active GitHub CLI credential. Sign in with gh first.")
        }
        return GitHubCredentials(token: token)
    }
    typealias GitRunner = @Sendable ([String], String?, [String: String]) async throws -> CommandOutput
    func push(_ plan: PullRequestPlan, project: Project, execute: GitRunner = { args, cwd, environment in
        try await CommandProcess().run(executable: "/usr/bin/git", arguments: args, cwd: cwd, environment: environment, isolatedEnvironment: true)
    }) async throws {
        try await TaskWorkspaces.validatePublication(plan, project: project)
        let slug = try GitHubClient.validateSlug(plan.binding.repository.full_name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // A temporary bare repository reads local objects without inheriting project/global config,
        // SSH identities, credential helpers, URL rewrites, hooks, or extra authorization headers.
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        let initialized = try await execute(["init", "--bare", directory.path], nil, environment)
        guard initialized.status == 0 else { throw MochletError.message("Could not prepare isolated Git publication transport.") }
        environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = URL(fileURLWithPath: plan.workspace.commonDirectory).appendingPathComponent("objects").path
        environment["MOCHLET_PUBLICATION_TOKEN"] = token
        // Static helper code only. Token bytes travel through the child environment, never command arguments or a file.
        let helper = "!f() { if test \"$1\" = get; then printf 'username=x-access-token\\npassword=%s\\n' \"$MOCHLET_PUBLICATION_TOKEN\"; fi; }; f"
        let args = ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "credential.helper=" + helper,
            "-c", "http.followRedirects=false", "push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no",
            "--force-with-lease=refs/heads/\(plan.workspace.branch):", "https://github.com/\(slug).git",
            "\(plan.headSHA):refs/heads/\(plan.workspace.branch)"]
        let result = try await execute(args, directory.path, environment)
        guard result.status == 0 else { throw MochletError.message("GitHub branch push failed (exit \(result.status)). Reconcile its outcome before continuing.") }
    }
}

extension GitHubPublisher {
    public static func authenticated(store: Store, executable: String) async throws -> GitHubPublisher {
        let credential = try await GitHubCredentials.load(executable: executable)
        return GitHubPublisher(store: store, api: PullRequestAPI(token: credential.token), push: { try await credential.push($0, project: $1) })
    }
}
