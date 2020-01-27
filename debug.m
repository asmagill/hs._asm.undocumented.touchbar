@import Cocoa ;
@import LuaSkin ;
@import Accelerate ;
@import QuartzCore ;

#import "TouchBar.h"

// static const char *USERDATA_TAG = "hs._asm.undocumented.touchbar.debug" ;
static int refTable = LUA_NOREF;

#pragma mark - Support Functions and Classes

#pragma mark - Module Functions

static int debug_dfrGetStatus(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    lua_pushinteger(L, DFRGetStatus()) ;
    return 1 ;
}

static int debug_dfrSetStatus(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TBREAK] ;

    lua_pushboolean(L, DFRSetStatus((int)lua_tointeger(L, 1))) ;
    return 1 ;
}

static int debug_touchbarSize(lua_State __unused *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    CGSize touchbarSize = DFRGetScreenSize() ;
    [skin pushNSSize:NSSizeFromCGSize(touchbarSize)] ;
    return 1 ;
}

#pragma mark - Hammerspoon/Lua Infrastructure

// Functions for returned object when module loads
static luaL_Reg moduleLib[] = {
    {"dfrGetStatus", debug_dfrGetStatus},
    {"dfrSetStatus", debug_dfrSetStatus},
    {"touchbarSize", debug_touchbarSize},
    {NULL,           NULL}
};

int luaopen_hs__asm_undocumented_touchbar_debug(lua_State* __unused L) {
    LuaSkin *skin = [LuaSkin shared] ;
    refTable = [skin registerLibrary:moduleLib metaFunctions:nil] ;

    return 1;
}
