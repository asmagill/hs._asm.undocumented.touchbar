@import Cocoa ;
@import LuaSkin ;
@import Accelerate ;
@import QuartzCore ;

#import "TouchBar.h"

// NOTE: should probably rework documentation to refer to it as a Virtual Touch Bar.

static const char *USERDATA_TAG = "hs._asm.undocumented.touchbar" ;
static int        refTable      = LUA_NOREF ;
static int        initialDFRStatus ;

#define get_objectFromUserdata(objType, L, idx, tag) (objType*)*((void**)luaL_checkudata(L, idx, tag))

#pragma mark - Support Functions and Classes

static inline NSRect RectWithFlippedYCoordinate(NSRect theRect) {
    return NSMakeRect(theRect.origin.x,
                      [[NSScreen screens][0] frame].size.height - theRect.origin.y - theRect.size.height,
                      theRect.size.width,
                      theRect.size.height) ;
}

@interface ASMTouchBarView : NSView
@property CGDisplayStreamRef stream ;
@property NSView             *displayView ;
@property BOOL               passMouseEvents ;
@property CGContextRef       context ;
@end

@implementation ASMTouchBarView {}

- (instancetype) init {
    self = [super init] ;
    if(self != nil) {
        _passMouseEvents = YES ;
        _displayView = [NSView new] ;

        CGSize tbScreenSize = DFRGetScreenSize() ;

        _displayView.frame = NSMakeRect(5, 5, tbScreenSize.width, tbScreenSize.height) ;
        _displayView.wantsLayer = YES ;
        [self addSubview:_displayView] ;

        _stream = SLSDFRDisplayStreamCreate(NULL, dispatch_get_main_queue(), ^(CGDisplayStreamFrameStatus status,
                                                                               __unused uint64_t displayTime,
                                                                               IOSurfaceRef frameSurface,
                                                                               __unused CGDisplayStreamUpdateRef updateRef) {
            if (status != kCGDisplayStreamFrameStatusFrameComplete) return ;
            self->_displayView.layer.contents = (__bridge id)(frameSurface) ;

// https://github.com/steventroughtonsmith/TouchBarScreenshotter/blob/master/TouchBarScreenshotter/AppDelegate.m
            IOSurfaceRef surface = frameSurface ;

            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nil) ;
            void   *frameBase  = IOSurfaceGetBaseAddress(surface) ;
            size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface) ;
            size_t height      = IOSurfaceGetHeight(surface) ;
            size_t width       = IOSurfaceGetWidth(surface) ;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3) ;
#pragma clang diagnostic pop

            vImage_Buffer src ;
            src.height   = height ;
            src.width    = width ;
            src.rowBytes = bytesPerRow ;
            src.data     = frameBase ;

            vImage_Buffer dest ;
            dest.height   = height ;
            dest.width    = width ;
            dest.rowBytes = bytesPerRow ;
            dest.data     = malloc(bytesPerRow*height) ;

            // Swap pixel channels from BGRA to RGBA.
            const uint8_t map[4] = { 2, 1, 0, 3 } ;
            vImagePermuteChannels_ARGB8888(&src, &dest, map, kvImageNoFlags) ;

            self->_context = CGBitmapContextCreate (dest.data,
                                             width,
                                             height,
                                             8,
                                             bytesPerRow,
                                             colorSpace,
                                             kCGImageAlphaPremultipliedLast) ;

            CGColorSpaceRelease(colorSpace) ;
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nil) ;

            if (self->_context == NULL) {
                [LuaSkin logDebug:@"%s:unable to create context for toolbar image creation"] ;
            }

        }) ;

        // Enables applications to put things into the touch bar
        DFRSetStatus(2) ;

        // Likewise, CGDisplayStreamStop will pause updates
        CGDisplayStreamStart(_stream) ;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:_displayView.frame
                                                           options:( NSTrackingMouseEnteredAndExited |
                                                                     NSTrackingActiveAlways |
                                                                     NSTrackingInVisibleRect )
                                                             owner:self
                                                          userInfo:nil]] ;
#pragma clang diagnostic pop
    }

    return self ;
}

- (void)commonMouseEvent:(NSEvent *)event {
    if (_passMouseEvents) {
        NSPoint location = [_displayView convertPoint:[event locationInWindow] fromView:nil] ;
        DFRFoundationPostEventWithMouseActivity(event.type, location) ;
    }
}

- (void)mouseDown:(NSEvent *)event {
    [self commonMouseEvent:event] ;
}

- (void)mouseUp:(NSEvent *)event {
    [self commonMouseEvent:event] ;
}

- (void)mouseDragged:(NSEvent *)event {
    [self commonMouseEvent:event] ;
}

- (void)stopStreaming {
    if (_stream) CGDisplayStreamStop(_stream) ;
}

- (void)startStreaming {
    if (_stream) CGDisplayStreamStart(_stream) ;
}

@end

@interface NSWindow (Private)
- (void )_setPreventsActivation:(bool)preventsActivation ;
@end

@interface ASMTouchBarWindow : NSWindow
@property CGFloat inactiveAlpha ;
@property int     callbackRef ;
@property int     selfRefCount ;
@end

@implementation ASMTouchBarWindow

- (instancetype)init {
    self = [super init] ;
    if(self != nil) {
        _inactiveAlpha = .5 ;
        _callbackRef   = LUA_NOREF ;
        _selfRefCount  = 0 ;

        self.styleMask                  = NSTitledWindowMask | NSFullSizeContentViewWindowMask ;
        self.titlebarAppearsTransparent = YES ;
        self.titleVisibility            = NSWindowTitleHidden ;
        self.movable                    = NO ;
        self.acceptsMouseMovedEvents    = YES ;
        self.movableByWindowBackground  = YES ;
        self.level                      = CGWindowLevelForKey(kCGAssistiveTechHighWindowLevelKey) ;
        self.collectionBehavior         = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                                           NSWindowCollectionBehaviorStationary |
                                           NSWindowCollectionBehaviorIgnoresCycle |
                                           NSWindowCollectionBehaviorFullScreenDisallowsTiling) ;
        self.backgroundColor            = [NSColor blackColor] ;

        [self standardWindowButton:NSWindowCloseButton].hidden       = YES ;
        [self standardWindowButton:NSWindowFullScreenButton].hidden  = YES ;
        [self standardWindowButton:NSWindowZoomButton].hidden        = YES ;
        [self standardWindowButton:NSWindowMiniaturizeButton].hidden = YES ;
        [self _setPreventsActivation:YES] ;

        ASMTouchBarView *tbView = [ASMTouchBarView new] ;
        CGSize tbScreenSize = DFRGetScreenSize() ;
        [self setFrame:NSMakeRect(0, 0, tbScreenSize.width + 10, tbScreenSize.height + 10) display:YES] ;
        self.contentView                = tbView ;
    }

    return self ;
}

- (BOOL)canBecomeMainWindow {
    return NO ;
}

- (BOOL)canBecomeKeyWindow {
    return NO ;
}

- (void)callbackWith:(NSString *)message {
    if (_callbackRef != LUA_NOREF) {
        LuaSkin *skin = [LuaSkin shared] ;
        [skin pushLuaRef:refTable ref:_callbackRef] ;
        [skin pushNSObject:self] ;
        [skin pushNSObject:message] ;
        if (![skin protectedCallAndTraceback:2 nresults:0]) {
            [skin logError:[NSString stringWithFormat:@"%s:callback error:%@", USERDATA_TAG, [skin toNSObjectAtIndex:-1]]] ;
            lua_pop([skin L], 1) ;
        }
    }
}

- (void)mouseExited:(__unused NSEvent *)theEvent {
    self.alphaValue = _inactiveAlpha ;
    [self callbackWith:@"didExit"] ;
}

- (void)mouseEntered:(__unused NSEvent *)theEvent {
    self.alphaValue = 1.0 ;
    [self callbackWith:@"didEnter"] ;
}

@end

#pragma mark - Module Functions

/// hs._asm.undocumented.touchbar.new() -> touchbarObject | nil
/// Function
/// Creates a new touchbarObject representing a window which displays the Apple Touch Bar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the touchbarObject or nil if one could not be created
///
/// Notes:
///  * The most common reason a touchbarObject cannot be created is if your macOS version is not new enough. Type the following into your Hammerspoon console to check: `require("hs._asm.undocumented.touchbar").supported(true)`.
static int touchbar_new(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    [skin pushNSObject:[ASMTouchBarWindow new]] ;
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

    // 2 allows apps to put things into the touchbar, 0 disables this.
    // System icons are still present, though.
    // other numbers seem to have no effect -- bit 1 seems to be the toggle.
    // check with DFRGetStatus() always seems to return 0 or 2, but we'll treat
    // as bitfield just in case I'm wrong...

    if (lua_gettop(L) == 1) {
        lua_pushboolean(L, DFRSetStatus(lua_toboolean(L, 1) ? (DFRGetStatus() | 2) : (DFRGetStatus() & ~2))) ;
    } else {
        lua_pushboolean(L, ((DFRGetStatus() & 2) == 2) ? YES : NO) ;
    }
    return 1 ;
}

// static int touchbar_screenSize(lua_State __unused *L) {
//     LuaSkin *skin = [LuaSkin shared] ;
//     [skin checkArgs:LS_TBREAK] ;
//     CGSize touchbarSize = DFRGetScreenSize() ;
//     [skin pushNSSize:NSSizeFromCGSize(touchbarSize)] ;
//     return 1 ;
// }

#pragma mark - Module Methods

/// hs._asm.undocumented.touchbar:show([duration]) -> touchbarObject
/// Method
/// Display the touch bar window with an optional fade-in delay.
///
/// Parameters:
///  * `duration` - an optional number, default 0.0, specifying the fade-in time for the touch bar window.
///
/// Returns:
///  * the touchbarObject
///
/// Notes:
///  * This method does nothing if the window is already visible.
static int touchbar_show(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;
    NSTimeInterval    duration  = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0 ;

    if (touchbar.visible == NO) {
        CGFloat initialAlpha = [touchbar.contentView hitTest:[NSEvent mouseLocation]] ? 1.0 : touchbar.inactiveAlpha ;
        touchbar.alphaValue = (duration > 0) ? 0.0 : initialAlpha ;
        [(ASMTouchBarView *)touchbar.contentView startStreaming] ;
        [touchbar setIsVisible:YES] ;
        if (duration > 0.0) {
            [NSAnimationContext beginGrouping] ;
            [[NSAnimationContext currentContext] setDuration:duration] ;
            [[touchbar animator] setAlphaValue:1.0] ;
            [NSAnimationContext endGrouping] ;
        }
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

static int touchbar_streaming(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;
    if (lua_toboolean(L, 2)) {
        [(ASMTouchBarView *)touchbar.contentView startStreaming] ;
    } else {
        [(ASMTouchBarView *)touchbar.contentView stopStreaming] ;
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.undocumented.touchbar:hide([duration]) -> touchbarObject
/// Method
/// Display the touch bar window with an optional fade-out delay.
///
/// Parameters:
///  * `duration` - an optional number, default 0.0, specifying the fade-out time for the touch bar window.
///
/// Returns:
///  * the touchbarObject
///
/// Notes:
///  * This method does nothing if the window is already hidden.
///  * The value used in the sample code referenced in the module header is 0.1.
static int touchbar_hide(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;
    NSTimeInterval    duration  = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0 ;

    if (touchbar.visible == YES) {
        [(ASMTouchBarView *)touchbar.contentView stopStreaming] ;
        if (duration > 0.0) {
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
                context.duration = duration ;
                [[touchbar animator] setAlphaValue:0.0] ;
            } completionHandler:^{
                if(touchbar.alphaValue == 0.0) {
                    [touchbar setIsVisible:NO] ;
                }
            }] ;
        } else {
            touchbar.alphaValue = 0.0 ;
            [touchbar setIsVisible:NO] ;
        }
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.undocumented.touchbar:topLeft([point]) -> table | touchbarObject
/// Method
/// Get or set the top-left of the touch bar window.
///
/// Parameters:
///  * `point` - an optional table specifying where the top left of the touch bar window should be moved to.
///
/// Returns:
///  * if a value is provided, returns the touchbarObject; otherwise returns the current value.
///
/// Notes:
///  * A point table is a table with at least `x` and `y` key-value pairs which specify the coordinates on the computer screen where the window should be moved to.  Hammerspoon considers the upper left corner of the primary screen to be { x = 0.0, y = 0.0 }.
static int touchbar_topLeft(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    NSRect frame = RectWithFlippedYCoordinate(touchbar.frame) ;
    if (lua_gettop(L) == 1) {
        [skin pushNSPoint:frame.origin] ;
    } else {
        NSPoint point  = [skin tableToPointAtIndex:2] ;
        frame.origin.x = point.x ;
        frame.origin.y = point.y ;
        [touchbar setFrame:RectWithFlippedYCoordinate(frame) display:YES animate:NO] ;
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar:getFrame() -> table
/// Method
/// Gets the frame of the touch bar window
///
/// Parameters:
///  * None
///
/// Returns:
///  * a frame table with key-value pairs specifying the top left corner of the touch bar window and its width and height.
///
/// Notes:
///  * A frame table is a table with at least `x`, `y`, `h` and `w` key-value pairs which specify the coordinates on the computer screen of the window and its width (w) and height(h).
///  * This allows you to get the frame so that you can include its height and width in calculations - it does not allow you to change the size of the touch bar window itself.
static int touchbar_getFrame(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    NSRect frame = RectWithFlippedYCoordinate(touchbar.frame) ;
    if (lua_gettop(L) == 1) {
        [skin pushNSRect:frame] ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar:isVisible() -> boolean
/// Method
/// Returns a boolean indicating whether or not the touch bar window is current visible.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean specifying whether the touch bar window is visible (true) or not (false).
static int touchbar_isVisible(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;
    lua_pushboolean(L, touchbar.visible) ;
    return 1 ;
}

/// hs._asm.undocumented.touchbar:inactiveAlpha([alpha]) -> number | touchbarObject
/// Method
/// Get or set the alpha value for the touch bar window when the mouse is not hovering over it.
///
/// Parameters:
///  * alpha - an optional number between 0.0 and 1.0 inclusive specifying the alpha value for the touch bar window when the mouse is not over it.  Defaults to 0.5.
///
/// Returns:
///  * if a value is provided, returns the touchbarObject; otherwise returns the current value
static int touchbar_inactiveAlpha(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 1) {
        lua_pushnumber(L, touchbar.inactiveAlpha) ;
    } else {
        CGFloat newAlpha = luaL_checknumber(L, 2) ;
        touchbar.inactiveAlpha = ((newAlpha < 0.0) ? 0.0 : ((newAlpha > 1.0) ? 1.0 : newAlpha)) ;
        touchbar.alphaValue = [touchbar.contentView hitTest:[NSEvent mouseLocation]] ? 1.0 : touchbar.inactiveAlpha ;
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar:movable([state]) -> boolean | touchbarObject
/// Method
/// Get or set whether or not the touch bar window is movable by clicking on it and holding down the mouse button while moving the mouse.
///
/// Parameters:
///  * `state` - an optional boolean which specifies whether the touch bar window is movable (true) or not (false).  Default false.
///
/// Returns:
///  * if an argument is provided, returns the touchbarObject; otherwise returns the current value.
///
/// Notes:
///  * While the touch bar is movable, actions which require moving the mouse while clicking on the touch bar are not accessible.
///  * See also [hs._asm.undocumented.touchbar:acceptsMouseEvents](#acceptsMouseEvents).
static int touchbar_movable(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 1) {
        lua_pushboolean(L, touchbar.movable) ;
    } else {
        touchbar.movable = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar:acceptsMouseEvents([state]) -> boolean | touchbarObject
/// Method
/// Get or set whether or not the touch bar accepts mouse events.
///
/// Parameters:
///  * `state` - an optional boolean which specifies whether the touch bar accepts mouse events (true) or not (false).  Default true.
///
/// Returns:
///  * if an argument is provided, returns the touchbarObject; otherwise returns the current value.
///
/// Notes:
///  * This method can be used to prevent mouse clicks in the touch bar from triggering the touch bar buttons.
///  * This can be useful when [hs._asm.undocumented.touchbar:movable](#movable) is set to true to prevent accidentally triggering an action.
static int touchbar_acceptsMouseEvents(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 1) {
        lua_pushboolean(L, ((ASMTouchBarView *)touchbar.contentView).passMouseEvents) ;
    } else {
        ((ASMTouchBarView *)touchbar.contentView).passMouseEvents = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar:backgroundColor([color]) -> color | touchbarObject
/// Method
/// Get or set the background color for the touch bar window.
///
/// Parameters:
///  * `color` - an optional color table as defined in `hs.drawing.color` specifying the background color for the touch bar window.  Defaults to black, i.e. `{ white = 0.0, alpha = 1.0 }`.
///
/// Returns:
///  * if an argument is provided, returns the touchbarObject; otherwise returns the current value.
///
/// Notes:
///  * The visual effect of this method is to change the border color around the touch bar -- the touch bar itself remains the color as defined by the application which is providing the current touch bar items for display.
static int touchbar_backgroundColor(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 1) {
        [skin pushNSObject:touchbar.backgroundColor] ;
    } else {
        NSColor *newColor = [skin luaObjectAtIndex:2 toClass:"NSColor"] ;
        if (newColor) {
            touchbar.backgroundColor = newColor ;
        } else {
            touchbar.backgroundColor = [NSColor blackColor] ;
        }
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.undocumented.touchbar:setCallback(fn | nil) -> touchbarObject
/// Method
/// Sets the callback function for the touch bar window.
///
/// Parameters:
///  * `fn` - a function to set as the callback for the touch bar window, or nil to remove the existing callback function.
///
/// Returns:
///  * the touchbarObject
///
/// Notes:
///  * The function should expect 2 arguments and return none.  The arguments will be one of the following:
///
///    * obj, "didEnter" - indicates that the mouse pointer has entered the window containing the touch bar
///      * `obj`     - the touchbarObject the callback is for
///      * `message` - the message to the callback, in this case "didEnter"
///
///    * obj, "didExit" - indicates that the mouse pointer has exited the window containing the touch bar
///      * `obj`     - the touchbarObject the callback is for
///      * `message` - the message to the callback, in this case "didEnter"
static int touchbar_setCallback(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;

    touchbar.callbackRef = [skin luaUnref:refTable ref:touchbar.callbackRef] ;
    if (lua_type(L, 2) != LUA_TNIL) {
        lua_pushvalue(L, 2) ;
        touchbar.callbackRef = [skin luaRef:refTable] ;
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

static int touchbar_asImage(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    ASMTouchBarWindow *touchbar = [skin toNSObjectAtIndex:1] ;
    ASMTouchBarView   *touchBarView = touchbar.contentView ;


    CGImageRef imgRef  = CGBitmapContextCreateImage(touchBarView.context) ;
    if (imgRef == NULL) {
        lua_pushnil(L) ;
    } else {
        CGSize     imgSize = DFRGetScreenSize() ;

        NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:imgRef] ;
        NSImage          *image    = [[NSImage alloc] initWithSize:imgSize] ;
        [image addRepresentation:imageRep];

        [skin pushNSObject:image] ;
    }
    return 1 ;
}


//       during __gc do we need to remove callback from dispatch queue?

#pragma mark - Module Constants

#pragma mark - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

static int pushASMTouchBarWindow(lua_State *L, id obj) {
    ASMTouchBarWindow *value = obj ;
    value.selfRefCount++ ;
    void** valuePtr = lua_newuserdata(L, sizeof(ASMTouchBarWindow *)) ;
    *valuePtr = (__bridge_retained void *)value ;
    luaL_getmetatable(L, USERDATA_TAG) ;
    lua_setmetatable(L, -2) ;
    return 1 ;
}

id toASMTouchBarWindowFromLua(lua_State *L, int idx) {
    LuaSkin *skin = [LuaSkin shared] ;
    ASMTouchBarWindow *value ;
    if (luaL_testudata(L, idx, USERDATA_TAG)) {
        value = get_objectFromUserdata(__bridge ASMTouchBarWindow, L, idx, USERDATA_TAG) ;
    } else {
        [skin logError:[NSString stringWithFormat:@"expected %s object, found %s", USERDATA_TAG,
                                                   lua_typename(L, lua_type(L, idx))]] ;
    }
    return value ;
}

#pragma mark - Hammerspoon/Lua Infrastructure

static int userdata_tostring(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared] ;
//     ASMTouchBarWindow *obj = [skin luaObjectAtIndex:1 toClass:"ASMTouchBarWindow"] ;
    NSString *title = @"TouchBar" ;
    [skin pushNSObject:[NSString stringWithFormat:@"%s: %@ (%p)", USERDATA_TAG, title, lua_topointer(L, 1)]] ;
    return 1 ;
}

static int userdata_eq(lua_State* L) {
// can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
// so use luaL_testudata before the macro causes a lua error
    if (luaL_testudata(L, 1, USERDATA_TAG) && luaL_testudata(L, 2, USERDATA_TAG)) {
        LuaSkin *skin = [LuaSkin shared] ;
        ASMTouchBarWindow *obj1 = [skin luaObjectAtIndex:1 toClass:"ASMTouchBarWindow"] ;
        ASMTouchBarWindow *obj2 = [skin luaObjectAtIndex:2 toClass:"ASMTouchBarWindow"] ;
        lua_pushboolean(L, [obj1 isEqualTo:obj2]) ;
    } else {
        lua_pushboolean(L, NO) ;
    }
    return 1 ;
}

static int userdata_gc(lua_State* L) {
    ASMTouchBarWindow *obj = get_objectFromUserdata(__bridge_transfer ASMTouchBarWindow, L, 1, USERDATA_TAG) ;
    if (obj) {
        obj.selfRefCount-- ;
        if (obj.selfRefCount == 0) {
            LuaSkin *skin = [LuaSkin shared] ;
            obj.callbackRef = [skin luaUnref:refTable ref:obj.callbackRef] ;
            // not sure what else to do to cleanup... if I do [obj close] on the window, it crashes...
            obj.alphaValue = 0.0 ;
            [obj setIsVisible:NO] ;
            [(ASMTouchBarView *)obj.contentView stopStreaming] ;
            obj = nil ;
        }
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L) ;
    lua_setmetatable(L, 1) ;
    return 0 ;
}

static int meta_gc(lua_State* __unused L) {
    // Under the assumption that this will already be 2 when the module loads on a machine with an
    // actual Touch Bar, we reset it to whatever it was when this module was first loaded.
    DFRSetStatus(initialDFRStatus) ;
    return 0 ;
}

// Metatable for userdata objects
static const luaL_Reg userdata_metaLib[] = {
    {"show",               touchbar_show},
    {"hide",               touchbar_hide},
    {"topLeft",            touchbar_topLeft},
    {"getFrame",           touchbar_getFrame},
    {"inactiveAlpha",      touchbar_inactiveAlpha},
    {"isVisible",          touchbar_isVisible},
    {"movable",            touchbar_movable},
    {"backgroundColor",    touchbar_backgroundColor},
    {"setCallback",        touchbar_setCallback},
    {"acceptsMouseEvents", touchbar_acceptsMouseEvents},
    {"image",              touchbar_asImage},
    {"streaming",          touchbar_streaming},

    {"__tostring",         userdata_tostring},
    {"__eq",               userdata_eq},
    {"__gc",               userdata_gc},
    {NULL,                 NULL}
} ;

// Functions for returned object when module loads
static luaL_Reg moduleLib[] = {
    {"new",     touchbar_new},
    {"enabled", touchbar_enabled},
//     {"size",    touchbar_screenSize},

    {NULL,        NULL}
} ;

// Metatable for module, if needed
static const luaL_Reg module_metaLib[] = {
    {"__gc", meta_gc},
    {NULL,   NULL}
} ;

// NOTE: ** Make sure to change luaopen_..._internal **
int luaopen_hs__asm_undocumented_touchbar_internal(lua_State* __unused L) {
    LuaSkin *skin = [LuaSkin shared] ;
    refTable = [skin registerLibraryWithObject:USERDATA_TAG
                                     functions:moduleLib
                                 metaFunctions:module_metaLib
                               objectFunctions:userdata_metaLib] ;

// On the assumption that when this module first loads, this will be 0 on machines without
// a touch bar and 2 on machines with a touch bar, save what it actually is for the meta_gc
    initialDFRStatus = DFRGetStatus() ;

    // Makes DFRGetScreenSize return the correct values
    DFRSetStatus(2) ;

    [skin registerPushNSHelper:pushASMTouchBarWindow         forClass:"ASMTouchBarWindow"] ;
    [skin registerLuaObjectHelper:toASMTouchBarWindowFromLua forClass:"ASMTouchBarWindow"
                                                  withUserdataMapping:USERDATA_TAG] ;

    return 1 ;
}
