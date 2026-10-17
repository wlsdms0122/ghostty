import SwiftUI

/// The bar's "+": a new group at the end of the row, a new tab at the end of a group.
struct CustomTabAddButton: View {
    let help: String

    /// The side of the square. Inside a group it matches a tab's height, so a group
    /// doesn't change height when its tabs come and go.
    let size: CGFloat

    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHovering ? 0.12 : 0.04))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
