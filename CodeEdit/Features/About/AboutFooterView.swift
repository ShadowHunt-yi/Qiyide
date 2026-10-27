//
//  AboutFooterView.swift
//  CodeEdit
//
//  Created by Giorgi Tchelidze on 08.06.25.
//

import SwiftUI
import AboutWindow

struct AboutFooterView: View {
    var body: some View {
        FooterView(
            primaryView: {
                HStack(spacing: 6) {
                    // 来源与许可证入口：应用内的「关于」窗口也需明确二开来源，
                    // 不能只靠版权行里的括号说明。
                    Link(destination: URL(string: "https://github.com/CodeEditApp/CodeEdit")!) {
                        Text("Based on CodeEdit")
                            .underline()
                    }
                    Text("·")
                    Link(destination: URL(string: "https://github.com/ShadowHunt-yi/CodeEdit/blob/main/LICENSE.md")!) {
                        Text("MIT License")
                            .underline()
                    }
                }
            },
            secondaryView: {
                Text(Bundle.copyrightString ?? "")
            }
        )
    }
}
