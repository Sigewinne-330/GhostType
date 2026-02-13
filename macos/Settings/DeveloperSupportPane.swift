import SwiftUI

struct DeveloperSupportPane: View {
    @ObservedObject var prefs: UserPreferences

    private var bundle: Bundle { .main }

    private var appName: String {
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundleName
        }
        return "GhostType"
    }

    private var version: String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "-"
    }

    private var build: String {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
    }

    var body: some View {
        DetailContainer(
            icon: "person.crop.circle.badge.questionmark",
            title: prefs.ui("开发者与支持", "Developer & Support"),
            subtitle: prefs.ui("联系开发者、反馈问题与查看版本", "Contact developer, send feedback, and view version")
        ) {
            Form {
                Section(prefs.ui("项目信息", "Project Information")) {
                    LabeledContent(prefs.ui("项目", "Project"), value: "GhostType (Open Source)")
                    LabeledContent(prefs.ui("许可证", "License"), value: "MIT")
                }

                Section(prefs.ui("支持与反馈", "Support & Feedback")) {
                    Text(prefs.ui("欢迎通过 GitHub 提交 Issue 或参与讨论。", "Feel free to open an Issue or join Discussions on GitHub."))
                    Link("GitHub Repository", destination: URL(string: "https://github.com/never13254/GhostType")!)
                    Text(
                        prefs.ui(
                            "GhostType 是一个社区驱动的开源项目，欢迎贡献代码和提示词优化。",
                            "GhostType is a community-driven open source project. Contributions and prompt improvements are welcome."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(prefs.ui("版本信息", "Version Information")) {
                    LabeledContent(
                        prefs.ui("当前版本", "Current Version"),
                        value: "\(appName) v\(version) (\(build))"
                    )
                    Text(
                        prefs.ui(
                            "版本标识已从设置页右上角移动到此页面。",
                            "The version badge has been moved here from the top-right of Settings."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}
