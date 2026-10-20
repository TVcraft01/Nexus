# ML Kit's text recognizer exposes one `TextRecognizer.initialize` entry point
# that names the options class of every script it ships — Latin, Chinese,
# Devanagari, Japanese, Korean. Nexus only ever asks for Latin, so the other
# option classes are not in the APK, and R8's release pass failed on the
# references to them: "Missing class ... ChineseTextRecognizerOptions".
#
# `-dontwarn` is the correct answer rather than bundling five extra script
# models for a phone that will never ask for them: the missing branches are
# unreachable from the Latin path the plugin actually calls. The `-keep` holds
# the recogniser and its options against being stripped, because the plugin
# reaches them through ML Kit's own entry points rather than through Nexus's
# code, which R8 cannot see.
-dontwarn com.google.mlkit.vision.text.**
-keep class com.google.mlkit.vision.text.** { *; }
