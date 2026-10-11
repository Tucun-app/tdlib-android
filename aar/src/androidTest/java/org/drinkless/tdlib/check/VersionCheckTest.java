package org.drinkless.tdlib.check;

import android.os.Bundle;
import android.util.Log;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.drinkless.tdlib.Client;
import org.drinkless.tdlib.TdApi;
import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

/** Loads the packaged libtdjni.so and reads the options TDLib answers synchronously. */
@RunWith(AndroidJUnit4.class)
public class VersionCheckTest {
    private static String option(String name) throws Exception {
        TdApi.OptionValue value = Client.execute(new TdApi.GetOption(name));
        assertTrue(name + " is not a string option", value instanceof TdApi.OptionValueString);
        return ((TdApi.OptionValueString) value).value;
    }

    @Test
    public void versionAndCommitMatchPinnedSource() throws Exception {
        Bundle args = InstrumentationRegistry.getArguments();
        String version = option("version");
        String commit = option("commit_hash");
        Log.i("TdlibVersionCheck", "version=" + version + " commit_hash=" + commit);
        assertEquals(args.getString("expectedVersion"), version);
        assertEquals(args.getString("expectedCommit"), commit);
    }
}
