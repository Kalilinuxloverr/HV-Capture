//
//  SessionReport.swift — eine Session als PDF-Bericht.
//
//  Rendert eine kompakte A4-Seite (Kopfdaten, Kennzahlen, Leistungskurve) über
//  ImageRenderer und schreibt sie als PDF in den temporären Ordner — teilbar
//  über das Share-Sheet, druckbar, ohne Tabellenprogramm lesbar.
//

import Charts
import SwiftUI
import UIKit

@MainActor
enum SessionReport {
    /// A4 bei 72 dpi.
    private static let pageSize = CGSize(width: 595, height: 842)

    static func pdf(for session: Session) -> URL? {
        let renderer = ImageRenderer(content: ReportPage(session: session)
            .frame(width: pageSize.width, height: pageSize.height))
        renderer.proposedSize = .init(pageSize)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(SessionStore.baseName(for: session)).pdf")

        var success = false
        renderer.render { size, renderInContext in
            var box = CGRect(origin: .zero, size: pageSize)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            success = true
        }
        return success ? url : nil
    }
}

/// Die gerenderte Seite. Bewusst hell (Papier), unabhängig vom App-Theme.
private struct ReportPage: View {
    let session: Session

    private func mmss(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
    private func dec1(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1)))
    }

    private var plotSamples: [Sample] {
        guard session.samples.count > 2000 else { return session.samples }
        let n = (session.samples.count + 1999) / 2000
        return stride(from: 0, to: session.samples.count, by: n).map { session.samples[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HV-Capture — Session-Bericht")
                    .font(.system(size: 22, weight: .bold))
                Text(session.started.formatted(date: .long, time: .standard))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    reportField("Elektrode", session.electrode)
                    reportField("Dauer", mmss(session.duration))
                }
                GridRow {
                    reportField("Bögen", "\(session.arcCount)")
                    reportField("Längster Bogen", dec1(session.longestArc ?? 0) + " s")
                }
                GridRow {
                    reportField("Spitzenleistung", "\(Int((session.peakWatts ?? 0).rounded())) W")
                    reportField("Spitzenstrom", dec1(session.peakAmps ?? 0) + " A")
                }
                GridRow {
                    reportField("Energie", dec1(session.wattHours) + " Wh")
                    reportField("Abschaltungen", "\(session.trips.count)")
                }
            }

            if plotSamples.count > 1 {
                Text("Leistungskurve")
                    .font(.system(size: 15, weight: .semibold))
                Chart(plotSamples) { s in
                    LineMark(x: .value("s", s.t), y: .value("W", s.w))
                        .foregroundStyle(.blue)
                }
                .chartXAxisLabel("s")
                .chartYAxisLabel("W")
                .frame(height: 240)
            }

            if !session.note.isEmpty {
                Text("Notiz")
                    .font(.system(size: 15, weight: .semibold))
                Text(session.note)
                    .font(.system(size: 12))
            }

            Spacer()

            Text("Erstellt mit HV-Capture · \(Date().formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private func reportField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
