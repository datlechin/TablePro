//
//  XLSXExportOptionsView.swift
//  XLSXExportPlugin
//

import SwiftUI

struct XLSXExportOptionsView: View {
    @Bindable var plugin: XLSXExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include column headers", isOn: $plugin.options.includeHeaderRow)
                .toggleStyle(.checkbox)

            Toggle("Convert NULL to empty", isOn: $plugin.options.convertNullToEmpty)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 13))
    }
}
