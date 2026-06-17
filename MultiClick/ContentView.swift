//
//  ContentView.swift
//  MultiClick
//

import SwiftUI

struct ContentView: View {
    @StateObject private var engine = ClickEngine()

    var body: some View {
        VStack(spacing: 16) {
            header

            if !engine.hasPermission {
                permissionBanner
            }

            armButton

            instructions

            Divider()

            pointsSection
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 480)
        .onAppear { engine.refreshPermission() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("MultiClick")
                .font(.largeTitle.bold())
            Text(engine.isArmed ? "Aktif — sağ tık ekler, sol tık tetikler"
                                 : "Kapalı — mouse normal çalışıyor")
                .font(.subheadline)
                .foregroundStyle(engine.isArmed ? .green : .secondary)
        }
    }

    private var permissionBanner: some View {
        VStack(spacing: 8) {
            Label("Erişilebilirlik izni gerekli", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text("Mouse tıklamalarını okuyup üretebilmek için bu izin gerekli.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("İzin İste") { engine.refreshPermission(prompt: true) }
                Button("Ayarları Aç") { engine.openAccessibilitySettings() }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var armButton: some View {
        Button(action: engine.toggleArmed) {
            Label(engine.isArmed ? "Durdur" : "Başlat",
                  systemImage: engine.isArmed ? "stop.fill" : "play.fill")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isArmed ? .red : .green)
        .disabled(!engine.hasPermission)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sağ tık: konum ekle", systemImage: "cursorarrow.click")
            Label("Sol tık: tüm konumlara tıkla", systemImage: "cursorarrow.click.2")
            Label("Esc: hemen durdur", systemImage: "escape")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Konumlar (\(engine.points.count))")
                    .font(.headline)
                Spacer()
                Button("Tümünü Temizle", action: engine.clearPoints)
                    .disabled(engine.points.isEmpty)
            }

            if engine.points.isEmpty {
                Text("Henüz konum yok. Başlat'a basıp ekrana sağ tıkla.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(Array(engine.points.enumerated()), id: \.element.id) { index, point in
                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text("x: \(Int(point.location.x))   y: \(Int(point.location.y))")
                                .monospacedDigit()
                            Spacer()
                            Button {
                                engine.removePoint(point)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 120)
            }
        }
    }
}

#Preview {
    ContentView()
}
