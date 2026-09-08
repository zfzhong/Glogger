package com.cmii.collector

/**
 * The animal on a card face.
 *
 * The server names block art with SF Symbol names ("hare.fill"), because the
 * iPad was first and draws them directly. Android has no such symbol set, so it
 * translates the name into something it can render.
 *
 * The NAME is what matters to the data: picture_id in _trials.csv stays
 * "hare.fill" on both platforms, so a scene can be matched across two tablets
 * regardless of what each one drew. Only the drawing differs.
 *
 * That difference is real and worth knowing about: Apple's symbol is a
 * monochrome outline, Android's is a colour emoji, and even the same emoji
 * codepoint is drawn differently by Apple and Google. If a participant is ever
 * meant to see an identical board on both tablets, the fix is a bundled vector
 * set shared by both apps, not a better mapping here.
 */
object Animals {

    /** The name written to the CSV when art is missing, not the drawing. */
    const val fallback = "pawprint.fill"

    /** SF Symbol name -> the character Android draws for it. */
    private val byName = mapOf(
        "hare.fill"      to "🐇",    // rabbit
        "tortoise.fill"  to "🐢",    // turtle
        "bird.fill"      to "🐦",    // bird
        "fish.fill"      to "🐟",    // fish
        "ladybug.fill"   to "🐞",    // lady beetle
        "ant.fill"       to "🐜",    // ant
        "lizard.fill"    to "🦎",    // lizard
        "cat.fill"       to "🐈",    // cat
        "dog.fill"       to "🐕",    // dog
        "teddybear.fill" to "🧸",    // teddy bear
        "pawprint.fill"  to "\uD83D\uDC3E"
    )

    /** The order the server's own pool is written in, for idle-screen art. */
    val all: List<String> = listOf(
        "hare.fill", "tortoise.fill", "bird.fill", "fish.fill", "ladybug.fill",
        "ant.fill", "lizard.fill", "cat.fill", "dog.fill", "teddybear.fill",
        "pawprint.fill")

    /**
     * An unknown name draws paw prints rather than nothing.
     *
     * A blank card is the failure this whole file exists to prevent: the
     * participant is cued to act on a block that looks empty, hesitates, and the
     * scene times out looking like a miss when the art was the only thing wrong.
     */
    fun glyph(name: String?): String {
        if (name.isNullOrBlank()) return pawGlyph
        return byName[name] ?: pawGlyph
    }

    /** What an unknown name is drawn as. `fallback` is its NAME, not this. */
    private const val pawGlyph = "🐾"
}
