package xendroid.compose.data

/** Container formats the library scan recognizes. XEX_FOLDER is a directory, not a
 *  filename match, so it is handled separately. */
enum class GameFormat {
    ISO, ZAR, GOD, XEX_FOLDER, STFS,

    /**
     * A loose `.xex` on its own, as opposed to [XEX_FOLDER]'s `default.xex`
     * inside a directory that IS the game.
     *
     * Its own value rather than reusing XEX_FOLDER, because two things differ
     * and both matter: the display name has an extension to strip, and - the
     * dangerous one - XEX_FOLDER's content is its PARENT DIRECTORY, so a
     * delete would take the whole folder the file happens to sit in.
     */
    XEX_FILE;

    /** Display name from a *file* name (XEX folders use the folder name verbatim). */
    fun displayNameFor(fileName: String): String = when (this) {
        ISO, ZAR, XEX_FILE -> fileName.dropLast(4)
        GOD, XEX_FOLDER, STFS -> fileName  // STFS containers are extensionless
    }

    /** Native title-id format code (MUST match the enum in emulator_xendroid.cpp).
     *  null for formats with no boot-free reader via title_id_from_path. */
    val titleIdCode: Int? get() = when (this) {
        ISO -> 0
        // Same code as XEX_FOLDER on purpose: the native side documents code 1
        // as "path = default.xex" and mmaps that path directly, which is
        // exactly what a standalone .xex is. No native change is needed.
        XEX_FOLDER, XEX_FILE -> 1
        ZAR -> 2
        GOD -> null        // GOD uses its own GameInfo reader
        STFS -> null       // STFS reads its title id from the content_header
    }

    companion object {
        /** File-name -> format, or null if ignored. Detection order matches the scan:
         *  .iso, then .zar, then .xex, then extensionless => GOD. */
        fun fromFileName(name: String): GameFormat? {
            val lower = name.lowercase()
            return when {
                lower.endsWith(".iso") -> ISO
                lower.endsWith(".zar") -> ZAR
                // A default.xex sitting inside its own folder never reaches
                // here - the directory branch of the scan claims the folder and
                // moves on - so this only ever sees a loose one.
                lower.endsWith(".xex") -> XEX_FILE
                !name.contains('.') -> GOD
                else -> null
            }
        }
    }
}
