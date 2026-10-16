import '../protocol/codex_remote_api.dart';

final class TurnSettings {
  const TurnSettings({this.model, this.effort, this.serviceTier = 'default'});

  final String? model;
  final String? effort;
  final String? serviceTier;
}

/// Use the same resolved settings for presentation and submission.
TurnSettings resolveTurnSettings(
  List<RemoteModel> models,
  TurnSettings value, {
  String? model,
  String? effort,
  bool useCatalogDefault = true,
}) {
  final name = value.model ??
      model ??
      (useCatalogDefault
          ? models.where((candidate) => candidate.isDefault).firstOrNull?.model
          : null);
  final entry = models.where((candidate) => candidate.model == name).firstOrNull;
  return TurnSettings(
    model: name,
    effort: (value.model != null ? value.effort : effort) ??
        entry?.defaultReasoningEffort,
    serviceTier: value.serviceTier,
  );
}
