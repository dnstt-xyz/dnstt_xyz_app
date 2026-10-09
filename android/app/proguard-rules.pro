# JSch selects crypto implementations with Class.forName. Keep the complete
# implementation package so R8 does not remove classes such as jce.Random.
-keep class com.jcraft.jsch.** { *; }
-dontwarn com.jcraft.jsch.**
