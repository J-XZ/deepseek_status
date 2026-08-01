import SwiftUI

/// DeepSeek 官方服务状态卡片。远程内容只作为纯文本展示。
struct DeepSeekServiceStatusView: View {
  @ObservedObject var store: DeepSeekStatusStore
  let language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L10n.string(.serviceTitle, language: language))
          .font(.headline)
        Spacer()
        overallBadge
      }

      switch store.loadState {
      case .idle, .loading:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(L10n.string(.serviceLoading, language: language))
            .foregroundStyle(.secondary)
        }
      case .unavailable:
        Text(L10n.string(.serviceUnavailable, language: language))
          .font(.caption)
          .foregroundStyle(.secondary)
      case .loaded:
        if let status = store.status {
          statusContent(status)
        } else {
          Text(L10n.string(.serviceUnavailable, language: language))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let error = store.error {
        Text(error.text(language: language))
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack(spacing: 8) {
        Button(L10n.string(.serviceRefresh, language: language)) {
          Task { await store.refresh() }
        }
        Button(L10n.string(.serviceOpenPage, language: language)) {
          store.openOfficialStatusPage()
        }
        Spacer()
      }
      .controlSize(.small)
    }
  }

  private var overallBadge: some View {
    let indicator = store.status?.overall ?? .unknown
    let text = overallText(indicator)
    return Text(text)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(overallColor(indicator).opacity(0.14), in: Capsule())
      .foregroundStyle(overallColor(indicator))
  }

  @ViewBuilder
  private func statusContent(_ status: DeepSeekServiceStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let updatedAt = store.lastSuccessfulUpdate {
        HStack(spacing: 6) {
          Text(
            L10n.string(
              .serviceLastUpdated,
              language: language,
              updatedAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
              )
            )
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          if store.isStale {
            Text(L10n.string(.serviceStale, language: language))
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
          }
        }
      }

      if !status.overallDescription.isEmpty {
        Text(status.overallDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      componentGroup(
        title: L10n.string(.serviceApi, language: language),
        components: status.apiComponents
      )
      componentGroup(
        title: L10n.string(.serviceWebChat, language: language),
        components: status.webChatComponents
      )
      if !status.otherComponents.isEmpty {
        componentGroup(
          title: L10n.string(.serviceOtherComponents, language: language),
          components: status.otherComponents
        )
      }

      if !status.incidents.isEmpty {
        Text(L10n.string(.serviceIncidents, language: language))
          .font(.caption.weight(.semibold))
        ForEach(status.incidents) { incident in
          incidentRow(incident)
        }
      }

      if !status.scheduledMaintenances.isEmpty {
        Text(L10n.string(.serviceMaintenance, language: language))
          .font(.caption.weight(.semibold))
        ForEach(status.scheduledMaintenances) { maintenance in
          maintenanceRow(maintenance)
        }
      }
    }
  }

  @ViewBuilder
  private func componentGroup(title: String, components: [DeepSeekServiceStatus.Component])
    -> some View
  {
    if !components.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(components) { component in
          HStack(spacing: 6) {
            Circle()
              .fill(componentColor(component.status))
              .frame(width: 8, height: 8)
            Text(component.name)
              .font(.caption)
              .foregroundStyle(.primary)
              .lineLimit(1)
            Spacer()
            Text(componentStatusText(component.status))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func incidentRow(_ incident: DeepSeekServiceStatus.Incident) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(incident.title)
        .font(.caption.weight(.medium))
        .textSelection(.enabled)
      HStack(spacing: 8) {
        Text(L10n.string(.serviceIncidentPhase, language: language, incidentStatusText(incident.status)))
        Text(L10n.string(.serviceIncidentImpact, language: language, impactText(incident.impact)))
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      if let updatedAt = incident.updatedAt {
        Text(
          L10n.string(
            .serviceIncidentUpdated,
            language: language,
            updatedAt.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
            )
          )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      if let body = incident.latestUpdateBody {
        Text(truncated(body))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  private func maintenanceRow(_ maintenance: DeepSeekServiceStatus.Maintenance) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(maintenance.title)
        .font(.caption.weight(.medium))
        .textSelection(.enabled)
      if let updatedAt = maintenance.updatedAt {
        Text(
          L10n.string(
            .serviceIncidentUpdated,
            language: language,
            updatedAt.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
            )
          )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  /// 超长远程纯文本截断，避免撑爆弹出窗口。
  private func truncated(_ text: String, limit: Int = 280) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…"
  }

  private func overallText(_ indicator: OverallIndicator) -> String {
    switch indicator {
    case .none:
      return L10n.string(.indicatorNone, language: language)
    case .minor:
      return L10n.string(.indicatorMinor, language: language)
    case .major:
      return L10n.string(.indicatorMajor, language: language)
    case .critical:
      return L10n.string(.indicatorCritical, language: language)
    case .maintenance:
      return L10n.string(.indicatorMaintenance, language: language)
    case .unknown:
      return L10n.string(.indicatorUnknown, language: language)
    }
  }

  private func overallColor(_ indicator: OverallIndicator) -> Color {
    switch indicator {
    case .none:
      return .green
    case .minor, .maintenance:
      return .yellow
    case .major:
      return .orange
    case .critical:
      return .red
    case .unknown:
      return .secondary
    }
  }

  private func componentStatusText(_ status: ComponentStatus) -> String {
    switch status {
    case .operational:
      return L10n.string(.componentOperational, language: language)
    case .degradedPerformance:
      return L10n.string(.componentDegraded, language: language)
    case .partialOutage:
      return L10n.string(.componentPartialOutage, language: language)
    case .majorOutage:
      return L10n.string(.componentMajorOutage, language: language)
    case .underMaintenance:
      return L10n.string(.componentUnderMaintenance, language: language)
    case .unknown:
      return L10n.string(.componentUnknown, language: language)
    }
  }

  private func componentColor(_ status: ComponentStatus) -> Color {
    switch status {
    case .operational:
      return .green
    case .degradedPerformance, .underMaintenance:
      return .yellow
    case .partialOutage:
      return .orange
    case .majorOutage:
      return .red
    case .unknown:
      return .secondary
    }
  }

  private func incidentStatusText(_ status: IncidentStatus) -> String {
    switch status {
    case .investigating:
      return L10n.string(.incidentInvestigating, language: language)
    case .identified:
      return L10n.string(.incidentIdentified, language: language)
    case .monitoring:
      return L10n.string(.incidentMonitoring, language: language)
    case .resolved:
      return L10n.string(.incidentResolved, language: language)
    case .postmortem:
      return L10n.string(.incidentPostmortem, language: language)
    case .unknown:
      return L10n.string(.incidentUnknown, language: language)
    }
  }

  private func impactText(_ impact: IncidentImpact) -> String {
    switch impact {
    case .none:
      return L10n.string(.impactNone, language: language)
    case .minor:
      return L10n.string(.impactMinor, language: language)
    case .major:
      return L10n.string(.impactMajor, language: language)
    case .critical:
      return L10n.string(.impactCritical, language: language)
    case .unknown:
      return L10n.string(.impactUnknown, language: language)
    }
  }
}
