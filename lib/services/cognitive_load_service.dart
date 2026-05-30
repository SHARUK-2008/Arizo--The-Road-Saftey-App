import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:flutter/widgets.dart';
import 'package:audioplayers/audioplayers.dart';

// ─── Drowsiness Level ─────────────────────────────────────────────────────────
enum DrowsinessLevel {
  alert,     // Eyes open, fully awake
  warning,   // Eyes closed 1.5–3s — drowsy
  sleeping,  // Eyes closed >3s — ALARM triggered
}

// ─── Data Model ───────────────────────────────────────────────────────────────
class CognitiveLoadData {
  final double loadPercentage;
  final double eyeOpenness;
  final int blinkRate;
  final String headPoseLabel;
  final String distractionLabel;
  final DrowsinessLevel drowsinessLevel;
  final double eyeClosedSeconds;

  CognitiveLoadData({
    required this.loadPercentage,
    required this.eyeOpenness,
    required this.blinkRate,
    required this.headPoseLabel,
    required this.distractionLabel,
    required this.drowsinessLevel,
    required this.eyeClosedSeconds,
  });

  factory CognitiveLoadData.initial() => CognitiveLoadData(
    loadPercentage: 0,
    eyeOpenness: 1.0,
    blinkRate: 15,
    headPoseLabel: 'Forward',
    distractionLabel: 'None',
    drowsinessLevel: DrowsinessLevel.alert,
    eyeClosedSeconds: 0,
  );
}

// ─── Service ──────────────────────────────────────────────────────────────────
class CognitiveLoadService {
  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  bool _isProcessing = false;
  void Function(CognitiveLoadData)? _onData;

  // Blink tracking
  final List<double> _eyeOpennessHistory = [];
  int _blinkCount = 0;
  DateTime _sessionStart = DateTime.now();
  double _prevEyeOpen = 1.0;

  // Eye closure duration tracking
  // Eyes below this = "closed"
  static const double _eyeClosedThreshold = 0.35;
  // Eyes above this = "open" (hysteresis to avoid flicker)
  static const double _eyeOpenThreshold = 0.55;

  DateTime? _eyeClosedSince;
  double _eyeClosedSeconds = 0;
  DrowsinessLevel _drowsinessLevel = DrowsinessLevel.alert;

  // Audio
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _alarmPlaying = false;
  bool _vibrateLoopActive = false;

  // Load smoothing
  final List<double> _loadHistory = [];

  // ─── Start ──────────────────────────────────────────────────────────────────
  Future<CameraController?> start(
      void Function(CognitiveLoadData) onData) async {
    _onData = onData;
    _sessionStart = DateTime.now();
    _blinkCount = 0;
    _eyeClosedSince = null;
    _eyeClosedSeconds = 0;
    _drowsinessLevel = DrowsinessLevel.alert;
    _alarmPlaying = false;
    _vibrateLoopActive = false;

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,  // eye open probability
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    final cameras = await availableCameras();
    if (cameras.isEmpty) return null;

    final front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21, // use bgra8888 on iOS
    );

    await _cameraController!.initialize();
    _cameraController!.startImageStream(_processFrame);

    return _cameraController;
  }

  // ─── Frame Processing ────────────────────────────────────────────────────────
  void _processFrame(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }

      final inputImage = InputImage.fromBytes(
        bytes: allBytes.done().buffer.asUint8List(),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation270deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );

      final faces = await _faceDetector!.processImage(inputImage);

      if (faces.isNotEmpty) {
        final face = faces.first;

        // ── Raw eye openness ─────────────────────────────────────────────────
        final leftEye = face.leftEyeOpenProbability ?? 1.0;
        final rightEye = face.rightEyeOpenProbability ?? 1.0;
        final eyeOpen = (leftEye + rightEye) / 2.0;

        // ── Blink detection (fast open→close transition) ─────────────────────
        if (_prevEyeOpen > 0.75 && eyeOpen < 0.3) _blinkCount++;
        _prevEyeOpen = eyeOpen;

        final elapsed = DateTime.now().difference(_sessionStart).inSeconds;
        final blinkRate = elapsed > 0
            ? ((_blinkCount / elapsed) * 60).round().clamp(0, 50)
            : 15;

        // ── Sustained eye-closure tracking ───────────────────────────────────
        final now = DateTime.now();

        if (eyeOpen < _eyeClosedThreshold) {
          // Eyes are closed — start or continue timer
          _eyeClosedSince ??= now;
          _eyeClosedSeconds =
              now.difference(_eyeClosedSince!).inMilliseconds / 1000.0;
        } else if (eyeOpen > _eyeOpenThreshold) {
          // Eyes reopened — reset everything
          _eyeClosedSince = null;
          _eyeClosedSeconds = 0;
          if (_alarmPlaying) _stopAlarm();
        }
        // In the hysteresis zone (_eyeClosedThreshold to _eyeOpenThreshold)
        // we keep the previous state — no change.

        // ── Drowsiness state machine ─────────────────────────────────────────
        final prevLevel = _drowsinessLevel;

        if (_eyeClosedSeconds >= 3.0) {
          _drowsinessLevel = DrowsinessLevel.sleeping;
        } else if (_eyeClosedSeconds >= 1.5) {
          _drowsinessLevel = DrowsinessLevel.warning;
        } else {
          _drowsinessLevel = DrowsinessLevel.alert;
        }

        // ── Alarm triggers ───────────────────────────────────────────────────
        if (_drowsinessLevel == DrowsinessLevel.sleeping && !_alarmPlaying) {
          _triggerAlarm(); // plays sound + repeating vibration
        }

        if (_drowsinessLevel == DrowsinessLevel.warning &&
            prevLevel == DrowsinessLevel.alert) {
          // Warning onset: single heavy haptic pulse
          HapticFeedback.heavyImpact();
        }

        // ── Smooth eye openness ──────────────────────────────────────────────
        _eyeOpennessHistory.add(eyeOpen);
        if (_eyeOpennessHistory.length > 10) _eyeOpennessHistory.removeAt(0);
        final smoothEye = _eyeOpennessHistory.reduce((a, b) => a + b) /
            _eyeOpennessHistory.length;

        // ── Head pose ────────────────────────────────────────────────────────
        final yaw = face.headEulerAngleY ?? 0;
        final pitch = face.headEulerAngleX ?? 0;
        final headPose = _classifyHeadPose(yaw, pitch);

        // ── Cognitive load score ─────────────────────────────────────────────
        // Extra boost when eyes stay closed (sleep scenario)
        final sleepBoost = (_eyeClosedSeconds * 12).clamp(0.0, 45.0);
        final eyeScore = ((1.0 - smoothEye) * 40) + sleepBoost;
        final blinkScore = _blinkPenalty(blinkRate);
        final headScore = _headPenalty(yaw, pitch);
        final noiseScore = Random().nextDouble() * 3;

        final rawLoad =
        (eyeScore + blinkScore + headScore + noiseScore).clamp(5.0, 99.0);

        _loadHistory.add(rawLoad);
        if (_loadHistory.length > 5) _loadHistory.removeAt(0);
        final smoothLoad =
            _loadHistory.reduce((a, b) => a + b) / _loadHistory.length;

        final distraction = smoothLoad > 70
            ? 'HIGH'
            : smoothLoad > 45
            ? 'MODERATE'
            : 'NONE';

        _onData?.call(CognitiveLoadData(
          loadPercentage: smoothLoad,
          eyeOpenness: smoothEye,
          blinkRate: blinkRate,
          headPoseLabel: headPose,
          distractionLabel: distraction,
          drowsinessLevel: _drowsinessLevel,
          eyeClosedSeconds: _eyeClosedSeconds,
        ));
      }
    } catch (_) {
      // Frame skipped — no face detected
    } finally {
      _isProcessing = false;
    }
  }

  // ─── Alarm ────────────────────────────────────────────────────────────────
  Future<void> _triggerAlarm() async {
    if (_alarmPlaying) return;
    _alarmPlaying = true;

    // 1. Play looping alarm sound from assets/sounds/alarm.mp3
    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
    } catch (e) {
      debugPrint('Alarm audio error: $e');
    }

    // 2. Repeating vibration loop (runs concurrently)
    _startVibrationLoop();
  }

  void _startVibrationLoop() async {
    if (_vibrateLoopActive) return;
    _vibrateLoopActive = true;

    // Vibrate in aggressive bursts while alarm is active
    while (_alarmPlaying && _vibrateLoopActive) {
      await HapticFeedback.vibrate();
      await Future.delayed(const Duration(milliseconds: 300));
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _vibrateLoopActive = false;
  }

  Future<void> _stopAlarm() async {
    _alarmPlaying = false;
    _vibrateLoopActive = false;
    await _audioPlayer.stop();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  String _classifyHeadPose(double yaw, double pitch) {
    if (pitch < -15) return 'Nodding';
    if (pitch > 15) return 'Head Up';
    if (yaw.abs() < 10) return 'Forward';
    if (yaw < -10) return 'Looking Left';
    return 'Looking Right';
  }

  double _blinkPenalty(int blinkRate) {
    if (blinkRate < 8) return 20;
    if (blinkRate > 25) return 30;
    if (blinkRate > 18) return 15;
    return 5;
  }

  double _headPenalty(double yaw, double pitch) {
    final yawPenalty = (yaw.abs() / 45.0 * 10).clamp(0, 10);
    final pitchPenalty = pitch < -10 ? 10.0 : 0.0;
    return yawPenalty + pitchPenalty;
  }

  // ─── Stop ─────────────────────────────────────────────────────────────────
  void stop() {
    _stopAlarm();
    _audioPlayer.dispose();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _cameraController = null;
    _faceDetector?.close();
    _faceDetector = null;
    _blinkCount = 0;
    _eyeOpennessHistory.clear();
    _loadHistory.clear();
    _eyeClosedSince = null;
    _eyeClosedSeconds = 0;
    _drowsinessLevel = DrowsinessLevel.alert;
  }
}