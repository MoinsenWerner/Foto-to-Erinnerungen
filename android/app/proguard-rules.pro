# Only Latin OCR is used; these four language packs are optional.

# FOTO_OCR_R8_RUNTIME_START
# ML Kit uses runtime reflection/component discovery; keep its registrars and implementations.
-keep class * implements com.google.firebase.components.ComponentRegistrar { public <init>(); }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
# Latin OCR is sufficient. These four other language modules are optional.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
# FOTO_OCR_R8_RUNTIME_END
