/// Metrics captured for every single transcription.
class TranscriptionRecord {
  TranscriptionRecord({
    required this.id,
    required this.createdAt,
    required this.engineId,
    required this.engineName,
    required this.isOnline,
    required this.quantization,
    required this.deviceModel,
    required this.osVersion,
    required this.audioDurationMs,
    required this.speechDurationMs,
    required this.processingMs,
    required this.text,
    required this.role,
    this.endOfSpeechToFinalMs,
    this.modelLoadMs,
    this.peakRssBytes,
    this.networkLatencyMs,
    this.note,
    this.metadata = const {},
  });

  factory TranscriptionRecord.fromJson(Map<String, dynamic> j) => TranscriptionRecord(
        id: j['id'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        engineId: j['engineId'] as String,
        engineName: j['engineName'] as String? ?? j['engineId'] as String,
        isOnline: j['isOnline'] as bool? ?? false,
        quantization: j['quantization'] as String? ?? '',
        deviceModel: j['deviceModel'] as String? ?? '',
        osVersion: j['osVersion'] as String? ?? '',
        audioDurationMs: (j['audioDurationMs'] as num?)?.toInt() ?? 0,
        speechDurationMs: (j['speechDurationMs'] as num?)?.toInt() ?? 0,
        processingMs: (j['processingMs'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
        role: j['role'] as String? ?? 'final',
        endOfSpeechToFinalMs: (j['endOfSpeechToFinalMs'] as num?)?.toInt(),
        modelLoadMs: (j['modelLoadMs'] as num?)?.toInt(),
        peakRssBytes: (j['peakRssBytes'] as num?)?.toInt(),
        networkLatencyMs: (j['networkLatencyMs'] as num?)?.toInt(),
        note: j['note'] as String?,
        metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  final String id;
  final DateTime createdAt;
  final String engineId;
  final String engineName;
  final bool isOnline;
  final String quantization;
  final String deviceModel;
  final String osVersion;

  /// Length of the whole recording.
  final int audioDurationMs;

  /// Length of the audio actually sent to the engine (after VAD).
  final int speechDurationMs;

  /// Time the engine spent. Offline: sum over chunks. Online: round trip.
  final int processingMs;

  /// Time from the user stopping the recording to this text being ready.
  final int? endOfSpeechToFinalMs;

  /// Cold-start model load time, if the model was loaded for this run.
  final int? modelLoadMs;

  /// Peak resident memory of the app process during the run (best effort).
  final int? peakRssBytes;

  /// Online only: round trip minus the provider's own time.
  final int? networkLatencyMs;

  final String text;

  /// draft | final | rerun
  final String role;

  /// e.g. why the router chose this path.
  final String? note;
  final Map<String, dynamic> metadata;

  /// Real-time factor: processing time / audio processed. Lower is faster.
  double? get rtf => speechDurationMs > 0 ? processingMs / speechDurationMs : null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'engineId': engineId,
        'engineName': engineName,
        'isOnline': isOnline,
        'quantization': quantization,
        'deviceModel': deviceModel,
        'osVersion': osVersion,
        'audioDurationMs': audioDurationMs,
        'speechDurationMs': speechDurationMs,
        'processingMs': processingMs,
        'rtf': rtf,
        'endOfSpeechToFinalMs': endOfSpeechToFinalMs,
        'modelLoadMs': modelLoadMs,
        'peakRssBytes': peakRssBytes,
        'networkLatencyMs': networkLatencyMs,
        'text': text,
        'role': role,
        'note': note,
        'metadata': metadata,
      };
}

enum UpgradeState {
  /// Not a draft + upgrade recording.
  none,

  /// Draft is shown; waiting for the network to fetch the online transcript.
  pending,

  /// Online transcript arrived but the user had edited the draft: ask.
  conflict,

  /// Final text is settled.
  done,
}

/// One recording and everything produced from it.
class Recording {
  Recording({
    required this.id,
    required this.createdAt,
    required this.mode,
    required this.durationMs,
    this.audioPath,
    this.stoppedAt,
    this.upgradeState = UpgradeState.none,
    this.upgradeEngineId,
    this.upgradeError,
    this.draftText,
    this.editedText,
    this.pendingOnlineText,
    this.finalText,
    this.speechRanges = const [],
    List<TranscriptionRecord>? transcriptions,
  }) : transcriptions = transcriptions ?? [];

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        mode: j['mode'] as String? ?? '',
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        audioPath: j['audioPath'] as String?,
        stoppedAt: j['stoppedAt'] == null ? null : DateTime.parse(j['stoppedAt'] as String),
        upgradeState: UpgradeState.values.firstWhere(
          (s) => s.name == j['upgradeState'],
          orElse: () => UpgradeState.none,
        ),
        upgradeEngineId: j['upgradeEngineId'] as String?,
        upgradeError: j['upgradeError'] as String?,
        draftText: j['draftText'] as String?,
        editedText: j['editedText'] as String?,
        pendingOnlineText: j['pendingOnlineText'] as String?,
        finalText: j['finalText'] as String?,
        speechRanges: [
          for (final r in (j['speechRanges'] as List? ?? const []))
            [(r as List)[0] as int, r[1] as int]
        ],
        transcriptions: [
          for (final t in (j['transcriptions'] as List? ?? const []))
            TranscriptionRecord.fromJson(t as Map<String, dynamic>)
        ],
      );

  final String id;
  final DateTime createdAt;
  final String mode;
  final int durationMs;

  /// The saved original recording, or null once it has been deleted.
  String? audioPath;
  DateTime? stoppedAt;

  UpgradeState upgradeState;
  String? upgradeEngineId;
  String? upgradeError;

  /// Offline draft as produced by the model.
  String? draftText;

  /// The draft after the user changed it (null = untouched).
  String? editedText;

  /// Online transcript waiting for the user's decision in a conflict.
  String? pendingOnlineText;

  /// The settled transcript (what would go on to summarisation).
  String? finalText;

  /// Padded [from, to) sample ranges VAD marked as speech in the saved audio,
  /// so later runs (upgrade, re-run) see exactly the audio the draft saw.
  final List<List<int>> speechRanges;

  final List<TranscriptionRecord> transcriptions;

  bool get draftWasEdited => editedText != null && editedText != draftText;

  /// Text to show right now.
  String get displayText => finalText ?? editedText ?? draftText ?? '';
  bool get isDraft => finalText == null && draftText != null;

  TranscriptionRecord? latest({required bool online}) {
    for (final t in transcriptions.reversed) {
      if (t.isOnline == online) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'mode': mode,
        'durationMs': durationMs,
        'audioPath': audioPath,
        'stoppedAt': stoppedAt?.toIso8601String(),
        'upgradeState': upgradeState.name,
        'upgradeEngineId': upgradeEngineId,
        'upgradeError': upgradeError,
        'draftText': draftText,
        'editedText': editedText,
        'pendingOnlineText': pendingOnlineText,
        'finalText': finalText,
        'speechRanges': speechRanges,
        'transcriptions': [for (final t in transcriptions) t.toJson()],
      };
}

String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
