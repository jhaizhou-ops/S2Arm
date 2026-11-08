package org.s2arm.android;

import java.io.File;
import java.io.IOException;

/**
 * A0 layout metadata: the display name/version live in the active revision
 * (ctl/control.nacp), not at the game root. Pure Java so the host test can
 * cover a layout whose root only has current.json and revisions/.
 */
final class GameMetadata {
    private GameMetadata() {
    }

    static GamePack.Info read(File gameRoot, BootContract.Game boot) throws IOException, GamePack.BadPack {
        GamePack.Info info = new GamePack.Info();
        GamePack.describe(info, GamePack.read(new File(new File(gameRoot, boot.revisionDir), boot.control)));
        return info;
    }
}
