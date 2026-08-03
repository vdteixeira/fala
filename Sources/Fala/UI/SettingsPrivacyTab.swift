import FalaKit
import SwiftUI

// Ajustes › Privacidade — settings-window.dc.html, PRIVACIDADE section.
//
// DESIGN-HANDOFF.md §1 calls this "the emotional core". It is purely static
// content: a centred lock+waveform mark, the headline, the body, three
// reassurance rows and the trust badge. Every sentence comes from `PrivacyPane`,
// where tests pin it.
//
// Decorative per the mockup's own footer: the mark. It is therefore hidden from
// VoiceOver — the headline carries the meaning, and announcing "shield with
// waveform" would only get between the user and the sentence.

struct SettingsPrivacyTab: View {
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(spacing: theme.space.md) {
      PrivacyMark()
      Text(PrivacyPane.headline)
        .font(theme.type.title.font)
        .lineSpacing(theme.type.title.lineSpacing)
        .foregroundStyle(theme.color.text.primary)
        .multilineTextAlignment(.center)
      Text(PrivacyPane.body)
        .font(theme.type.body.font)
        .lineSpacing(theme.type.body.lineSpacing)
        .foregroundStyle(theme.color.text.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: SettingsLayout.privacyColumnWidth)
        .fixedSize(horizontal: false, vertical: true)
      rows
      badge
    }
    .frame(maxWidth: .infinity)
  }

  private var rows: some View {
    VStack(spacing: theme.space.xxs) {
      ForEach(PrivacyPane.rows) { row in
        HStack(spacing: theme.space.xs) {
          Image(systemName: row.symbol)
            .font(.system(size: SettingsLayout.smallIconSize))
            .foregroundStyle(theme.color.accent.base)
            .accessibilityHidden(true)
          Text(row.text)
            .font(theme.type.caption.font)
            .foregroundStyle(theme.color.text.primary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(.vertical, theme.space.xs)
        .padding(.horizontal, theme.space.md)
        .background(
          theme.color.bg.inset,
          in: RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
        )
        .accessibilityElement(children: .combine)
      }
    }
    .frame(maxWidth: SettingsLayout.privacyColumnWidth)
  }

  private var badge: some View {
    HStack(spacing: theme.space.xxs) {
      Image(systemName: PrivacyPane.badgeSymbol)
        .font(.system(size: SettingsLayout.smallIconSize))
      Text(PrivacyPane.badgeText)
        .font(SettingsType.softButton.font)
    }
    .foregroundStyle(theme.color.accent.base)
    .padding(.vertical, theme.space.xxs)
    .padding(.horizontal, theme.space.xs)
    .background(theme.color.accent.soft, in: Capsule())
    .overlay(Capsule().strokeBorder(theme.color.accent.base, lineWidth: SettingsLayout.hairline))
    .accessibilityElement(children: .combine)
  }
}

/// The 72pt accent-soft circle with a shield in it and three contained waveform
/// bars near the bottom. Decorative (mockup footer), so it is hidden from
/// VoiceOver and never animates.
private struct PrivacyMark: View {
  @Environment(\.theme) private var theme

  var body: some View {
    ZStack(alignment: .bottom) {
      Circle()
        .fill(theme.color.accent.soft)
        .frame(width: SettingsLayout.privacyMarkSize, height: SettingsLayout.privacyMarkSize)
      Image(systemName: PrivacyPane.markSymbol)
        .font(.system(size: SettingsLayout.privacyMarkGlyphSize))
        .foregroundStyle(theme.color.accent.base)
        .frame(width: SettingsLayout.privacyMarkSize, height: SettingsLayout.privacyMarkSize)
      waveform
        .padding(.bottom, SettingsLayout.privacyWaveformBottomInset)
    }
    .frame(width: SettingsLayout.privacyMarkSize, height: SettingsLayout.privacyMarkSize)
    .accessibilityHidden(true)
  }

  private var waveform: some View {
    HStack(alignment: .center, spacing: SettingsLayout.privacyWaveformBarSpacing) {
      ForEach(Array(SettingsLayout.privacyWaveformBarHeights.enumerated()), id: \.offset) {
        _, height in
        RoundedRectangle(
          cornerRadius: SettingsLayout.privacyWaveformBarRadius, style: .continuous
        )
        .fill(theme.color.accent.warm)
        .frame(width: SettingsLayout.privacyWaveformBarWidth, height: height)
      }
    }
  }
}
