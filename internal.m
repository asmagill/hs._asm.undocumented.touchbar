@import Cocoa ;
@import LuaSkin ;

// Weakly linking to these function *should* allow loading this file on machines running 10.12.1 or earlier, but I'll need to find one to test
extern BOOL   DFRSetStatus(int) __attribute__((weak_import)) ;
extern int    DFRGetStatus(void) __attribute__((weak_import)) ;

static BOOL is_supported() { return NSClassFromString(@"DFRElement") ? YES : NO ; }

/// hs._asm.undocumented.touchbar.supported([showLink]) -> boolean
/// Function
/// Returns a boolean value indicathing whether or not the Apple Touch Bar is supported on this Macintosh.
///
/// Parameters:
///  * `showLink` - a boolean, default false, specifying whether a dialog prompting the user to download the necessary update is presented if Apple Touch Bar support is not found in the current Operating System.
///
/// Returns:
///  * true if Apple Touch Bar support is found in the current Operating System or false if it is not.
///
/// Notes:
///  * the link in the prompt is https://support.apple.com/kb/dl1897
static int touchbar_supported(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    BOOL showDialog = (lua_gettop(L) == 1) ? (BOOL)lua_toboolean(L, 1) : NO ;
    lua_pushboolean(L, is_supported()) ;
    if (!lua_toboolean(L, -1) && showDialog) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Error: could not detect Touch Bar support"];
        [alert setInformativeText:[NSString stringWithFormat:@"We need at least macOS 10.12.1 (Build 16B2657).\n\nYou have: %@.\n", [NSProcessInfo processInfo].operatingSystemVersionString]];
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Get macOS Update"];
        NSModalResponse response = [alert runModal];
        if(response == NSAlertSecondButtonReturn) {
            NSURL *appleUpdateURL = [NSURL URLWithString:@"https://support.apple.com/kb/dl1897"] ;
            [[NSWorkspace sharedWorkspace] openURL:appleUpdateURL];
        }
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar.enabled([state]) -> boolean
/// Function
/// Get or set whether or not the Touch Bar can be used by applications.
///
/// Parameters:
///  * `state` - an optional boolean specifying whether applications can put items into the touch bar (true) or if this is limited only to the system items (false).
///
/// Returns:
///  * if an argument is provided, returns a boolean indicating whether or not the change was successful; otherwise returns the current value
///
/// Notes:
///  * Checking the value of this function does not indicate whether or not the machine *can* support the Touch Bar but rather if it *is* supporting the Touch Bar; Use [hs._asm.undocumented.touchbar.supported](#supported) to check whether or not the machine *can* support the Touch Bar.
///
///  * Setting this to false will remove all application items from the Touch Bar.
static int touchbar_enabled(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;

    if ((DFRGetStatus != NULL) && (DFRSetStatus != NULL)) {
        // best guess right now is that DFRStatus value is a bitfield
        //      bit 0 indicates if touchbar is physical (1) or virtual  (0)
        //      bit 1 indicates if touchbar is enabled  (1) or disabled (0)
        // but I stress this is *only* a guess based upon a very small sample size
        if (lua_gettop(L) == 1) {
            lua_pushboolean(L, DFRSetStatus(lua_toboolean(L, 1) ? (DFRGetStatus() | 2) : (DFRGetStatus() & ~2))) ;
        } else {
            lua_pushboolean(L, ((DFRGetStatus() & 2) == 2) ? YES : NO) ;
        }
    } else {
        lua_pushboolean(L, NO) ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar.touchbarReal() -> boolean
/// Function
/// Returns whether or not the machine has a physical touchbar
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not the machine has a physical touchbar (true) or does not (false)
///
/// Notes:
///  * To determine if the machine is currently maintaining a touchbar, physical *or* virtual, use [hs._asm.undocumented.touchbar.enabled](#enabled) with no arguments.
static int touchbar_hasPhysicalTouchbar(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    if (DFRGetStatus != NULL) {
        lua_pushboolean(L, ((DFRGetStatus() | 1) == 1)) ;
    } else {
        lua_pushboolean(L, NO) ;
    }
    return 1 ;
}

// placeholder
static int touchbar_fakeNew(lua_State *L) {
    lua_pushcfunction(L, touchbar_supported) ;
    lua_pushboolean(L, YES) ;
    lua_pcall(L, 1, 1, 0) ;
    lua_pop(L, 1) ; // pedantic, but let's clean up after ourselves since we're ignoring this.
    lua_pushnil(L) ;
    return 1 ;
}

// Functions for returned object when module loads
static luaL_Reg moduleLib[] = {
    {"supported",    touchbar_supported},
    {"enabled",      touchbar_enabled},
    {"touchbarReal", touchbar_hasPhysicalTouchbar},

    {"_fakeNew",     touchbar_fakeNew},

    {NULL,        NULL}
};

int luaopen_hs__asm_undocumented_touchbar_internal(lua_State* __unused L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin registerLibrary:moduleLib metaFunctions:nil] ;

    return 1;
}
