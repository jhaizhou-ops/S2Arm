package org.s2arm.android;

import java.io.File;

/** Host check for the formal A0 layout: metadata comes from the revision, not the game root. */
public final class GameMetadataTest {
    private static int failures;

    private static void check(boolean ok, String what) {
        if (!ok) {
            System.err.println("FAILED: " + what);
            failures++;
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: GameMetadataTest <game-root>");
            System.exit(2);
        }
        File root = new File(args[0]);
        BootContract.Game boot = BootContract.open(root);
        GamePack.Info info = GameMetadata.read(root, boot);
        check(info.titleId.equals(boot.titleId), "metadata titleId matches artifact");
        check(!info.name.isEmpty(), "metadata name is not empty");
        check(!info.version.isEmpty(), "metadata version is not empty");
        System.out.println("GameMetadata: " + info.name + " " + info.version + " [" + info.titleId + "]");
        System.out.println(failures == 0 ? "GameMetadata: ok" : "GameMetadata: " + failures + " FAILED");
        if (failures != 0) System.exit(1);
    }
}
