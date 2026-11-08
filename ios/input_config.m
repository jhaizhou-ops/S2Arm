// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#include "input_config.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include <stdlib.h>
static s2a_input_config current_config;
static int current_valid;
int s2a_ios_input_config_read(const char *path, s2a_input_config *out) {
    if (!out) return S2A_INPUT_CONFIG_JSON;
    if (!path) { s2a_input_config_default(out); return S2A_INPUT_CONFIG_OK; }
    @try {
        NSString *name = [[NSString alloc] initWithUTF8String:path];
        if (!name) return S2A_INPUT_CONFIG_IO;
        if (!name.isAbsolutePath) {
            char docs[1024]; s2a_docs_root(docs, sizeof docs);
            NSString *root = [[NSString alloc] initWithUTF8String:docs];
            if (!root) return S2A_INPUT_CONFIG_IO;
            name = [root stringByAppendingPathComponent:name];
        }
        NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:name];
        if (!file) return S2A_INPUT_CONFIG_IO;
        NSData *data = [file readDataUpToLength:S2A_INPUT_CONFIG_MAX_BYTES + 1 error:NULL]; [file closeFile];
        return data ? s2a_input_config_parse(data.bytes, data.length, out) : S2A_INPUT_CONFIG_IO;
    } @catch (NSException *exception) { (void)exception; return S2A_INPUT_CONFIG_IO; }
}
int s2a_ios_input_config_load(void) {
    s2a_input_config next;
    int error = s2a_ios_input_config_read(getenv("S2A_INPUT_CONFIG"), &next);
    current_valid = !error;
    if (!error) current_config = next;
    return error;
}
const s2a_input_config *s2a_ios_input_config_current(void) { return current_valid ? &current_config : NULL; }
