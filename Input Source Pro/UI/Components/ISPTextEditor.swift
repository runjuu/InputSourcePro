//
//  ISPTextEditor.swift
//  Input Source Pro
//
//  Created by runjuu on 2023-03-05.
//

import SwiftUI

struct ISPTextEditor: View {
    @Binding var text: String

    var placeholder: String

    let minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .padding(.vertical, 7)
                .padding(.horizontal, 2)
                .frame(minHeight: minHeight, maxHeight: 500, alignment: .leading)
                .foregroundColor(Color(.labelColor))
                .multilineTextAlignment(.leading)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                )

            Text(placeholder)
                .padding(.vertical, 7)
                .padding(.horizontal, 7)
                .foregroundColor(Color(.placeholderTextColor))
                .opacity(text.isEmpty ? 1 : 0)
                .allowsHitTesting(false)
        }
        .font(.body)
    }
}
