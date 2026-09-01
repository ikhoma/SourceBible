// CommentaryQuoteShareFormatter.swift
// SourceBible
//
// Формує рядок атрибуції для Share Sheet при виділенні тексту коментаря.
// Дзеркалить VerseShareFormatter (та сама em-dash-конвенція атрибуції).
// `ref` — той самий рядок, що CommentaryDetailView.detailTitle обчислює без
// імені теолога (воно йде окремим параметром) — атрибуція завжди береться з
// уже відомих координат секції, не з вмісту виділення (ADR-037 §3).

import Foundation

enum CommentaryQuoteShareFormatter {
    static func format(quote: String, theologianShortName: String, ref: String) -> String {
        "\u{201C}\(quote)\u{201D}\n\n— \(theologianShortName), \(ref)"
    }
}
