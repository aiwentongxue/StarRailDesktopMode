#import "Runtime.hpp"

#include "UnityCodeHooks.hpp"

namespace {

struct GraphicsAddresses {
    uintptr_t refresh, show, setValue, disable, select;
    uintptr_t applyCamera, activePipeline, roundSceneDimension, configureCamera, buildPostProcessing;
    uintptr_t classMethods, methodName, methodParameterCount, domain, openAssembly, assemblyImage, classFromName;
    uintptr_t componentTransform, transformParent, siblingIndex, screenWidth, screenHeight;
    uintptr_t textSet, optionTextSet, rect, transformPoint, position, setPosition, gameObjectTransform;
    uintptr_t allocateArray, writeBarrier;
};

constexpr GraphicsAddresses MainlandGraphics{
    .refresh = 0xf1ca830, .show = 0xf1cc384, .setValue = 0xf1cb4f8, .disable = 0xf1cb928, .select = 0xf1cdc50,
    .applyCamera = 0xd61cd60, .activePipeline = 0xd61b6ac, .roundSceneDimension = 0xf113474,
    .configureCamera = 0xd634848, .buildPostProcessing = 0xd64ed34,
    .classMethods = 0xf2c6f30, .methodName = 0xf2c7060, .methodParameterCount = 0xf2c7070,
    .domain = 0xf2c6fb0, .openAssembly = 0xf2c6fb4, .assemblyImage = 0xf2c6efc, .classFromName = 0xf2c6f20,
    .componentTransform = 0xf0f8fc0, .transformParent = 0xf146ea0, .siblingIndex = 0xf147fc0,
    .screenWidth = 0xf13b9c4, .screenHeight = 0xf13b9d4,
    .textSet = 0xf20bc5c, .optionTextSet = 0xf1ce0b4, .rect = 0xf1266c0, .transformPoint = 0xf147db0,
    .position = 0xf14673c, .setPosition = 0xf146788, .gameObjectTransform = 0xf106218,
    .allocateArray = 0xf2c88f4, .writeBarrier = 0xf2c7038,
};

constexpr GraphicsAddresses InternationalGraphics{
    .refresh = 0xf1c9784, .show = 0xf1cb2cc, .setValue = 0xf1ca44c, .disable = 0xf1ca878, .select = 0xf1ccb80,
    .applyCamera = 0xd61acd8, .activePipeline = 0xd619624, .roundSceneDimension = 0xf1124d8,
    .configureCamera = 0xd6327d8, .buildPostProcessing = 0xd64cd64,
    .classMethods = 0xf2c5f00, .methodName = 0xf2c6030, .methodParameterCount = 0xf2c6040,
    .domain = 0xf2c5f80, .openAssembly = 0xf2c5f84, .assemblyImage = 0xf2c5ecc, .classFromName = 0xf2c5ef0,
    .componentTransform = 0xf0f7f98, .transformParent = 0xf145ef8, .siblingIndex = 0xf147018,
    .screenWidth = 0xf13aa5c, .screenHeight = 0xf13aa6c,
    .textSet = 0xf20aaa8, .optionTextSet = 0xf1ccfe8, .rect = 0xf125744, .transformPoint = 0xf146e08,
    .position = 0xf145794, .setPosition = 0xf1457e0, .gameObjectTransform = 0xf1051f4,
    .allocateArray = 0xf2c78c4, .writeBarrier = 0xf2c6008,
};

NSString *const ScalePreference = @"SRDMDesktopRenderScale";
NSString *const MetalPreference = @"SRDMDesktopMetalFX";
constexpr std::array RenderRatios{0.f, 0.6f, 0.8f, 1.f};
enum class MetalMode { Off, Spatial, Temporal };

using DropdownMethod = void (*)(void *, void *);
using SetValueMethod = void (*)(void *, int, void *);
using SelectMethod = void (*)(void *, void *, void *);
using ApplyMethod = void (*)(void *, void *, void *, void *);
using BuildPostProcessingMethod = void (*)(void *, void *, void *);

intptr_t unitySlide;
const section_64 *unityText;
const GraphicsAddresses *addresses;
uintptr_t stringNewAddress;
DropdownMethod originalRefresh, originalShow, originalDisable;
SetValueMethod originalSetValue;
SelectMethod originalSelect;
ApplyMethod originalApply;
DropdownMethod originalConfigureCameraScale;
BuildPostProcessingMethod originalBuildPostProcessing;
void *resolutionRow;
void *selectingScale;
void *selectingMetal;
CGSize shownResolution;
bool installed;
size_t renderSelection;
MetalMode metalMode;
bool metalSupportChecked;
bool nativeMetalSupported;
bool temporalAvailable;
bool useChineseLabels;

template <typename Fn> Fn Unity(uintptr_t address) {
    return reinterpret_cast<Fn>(unitySlide + address);
}

template <typename T> T &Field(void *object, size_t offset) {
    return *reinterpret_cast<T *>(static_cast<char *>(object) + offset);
}

NSString *ManagedString(void *text) {
    if (!text) return nil;
    int length = Field<int>(text, 0x10);
    if (length < 1 || length > 128) return nil;
    return [NSString stringWithCharacters:&Field<unichar>(text, 0x14) length:length];
}

void *ManagedClass(const char *assemblyName, const char *nameSpace, const char *name) {
    void *domain = Unity<void *(*)()>(addresses->domain)();
    if (!domain) return nullptr;
    void *assembly = Unity<void *(*)(void *, const char *)>(addresses->openAssembly)(domain, assemblyName);
    if (!assembly) return nullptr;
    void *image = Unity<void *(*)(void *)>(addresses->assemblyImage)(assembly);
    return image ? Unity<void *(*)(void *, const char *, const char *)>(addresses->classFromName)(image, nameSpace, name)
                 : nullptr;
}

void *ManagedMethod(void *klass, const char *name, int count) {
    if (!klass) return nullptr;
    auto methods = Unity<void *(*)(void *, void **)>(addresses->classMethods);
    auto methodName = Unity<const char *(*)(void *)>(addresses->methodName);
    auto parameterCount = Unity<int (*)(void *)>(addresses->methodParameterCount);
    void *iterator = nullptr;
    while (void *method = methods(klass, &iterator)) {
        const char *candidate = methodName(method);
        if (candidate && strcmp(candidate, name) == 0 && parameterCount(method) == count) return method;
    }
    return nullptr;
}

template <typename Fn> struct ManagedCall {
    Fn code = nullptr;
    void *method = nullptr;

    bool resolve(void *klass, const char *name, int count) {
        method = ManagedMethod(klass, name, count);
        if (!method) return false;
        const auto entry = Field<uintptr_t>(method, sizeof(void *));
        if (!starrail::SectionContains(unityText, entry - unitySlide, sizeof(uint32_t))) return false;
        code = reinterpret_cast<Fn>(entry);
        return true;
    }
};

constexpr const char *UnityCore = "UnityEngine.CoreModule.dll";

struct UnityUi {
    using Receiver = void *(*)(void *, void *);
    using StringArgument = void *(*)(void *, void *, void *);
    ManagedCall<Receiver> objectName;
    ManagedCall<StringArgument> findTransform;
    ManagedCall<Receiver> gameObject;
    ManagedCall<StringArgument> componentByName;
    ManagedCall<Receiver> textValue;

    bool resolve() {
        return objectName.code || objectName.resolve(ManagedClass(UnityCore, "UnityEngine", "Object"), "get_name", 0);
    }

    NSString *name(void *transform) const {
        return transform ? ManagedString(objectName.code(transform, objectName.method)) : nil;
    }

    NSString *settingsTitle(void *contents);
};

UnityUi ui;

void *OptionList(void *dropdown) {
    void *wrapper = Field<void *>(dropdown, 0x138);
    return wrapper ? Field<void *>(wrapper, 0x10) : nullptr;
}

int OptionCount(void *dropdown) {
    void *list = OptionList(dropdown);
    return list ? Field<int>(list, 0x18) : 0;
}

void *Option(void *list, size_t index) {
    void *items = Field<void *>(list, 0x10);
    if (!items || index >= Field<size_t>(items, 0x18)) return nullptr;
    return Field<void *>(items, 0x20 + index * sizeof(void *));
}

int SettingsRowIndex(void *dropdown, void **rowContents = nullptr) {
    if (!ui.resolve()) return -1;
    const auto getTransform = Unity<UnityUi::Receiver>(addresses->componentTransform);
    const auto parent = Unity<UnityUi::Receiver>(addresses->transformParent);
    void *node = getTransform(dropdown, nullptr);
    const NSArray<NSString *> *path = @[@"DropDownPanelPC", @"FuctionArea", @"Contents", @"Root",
                                         @"SettingInfoRow(Clone)", @"Content", @"Viewport"];
    void *contents = nullptr;
    int index = -1;
    for (NSString *component in path) {
        if (![ui.name(node) isEqualToString:component]) return -1;
        if ([component isEqualToString:@"Contents"]) contents = node;
        if ([component isEqualToString:@"SettingInfoRow(Clone)"])
            index = Unity<int (*)(void *, void *)>(addresses->siblingIndex)(node, nullptr);
        node = parent(node, nullptr);
    }
    if (rowContents) *rowContents = contents;
    return index;
}

bool IsResolutionRow(void *dropdown) {
    return dropdown && OptionCount(dropdown) == 5 && SettingsRowIndex(dropdown) == 1;
}

bool IsRenderScaleRow(void *dropdown) {
    if (!dropdown || OptionCount(dropdown) != 8) return false;
    void *option = Option(OptionList(dropdown), 0);
    return option && [ManagedString(Field<void *>(option, 0x10)) isEqualToString:@"0.6"] &&
           SettingsRowIndex(dropdown) == 3;
}

bool IsMetalRow(void *dropdown) {
    if (!nativeMetalSupported || !dropdown || OptionCount(dropdown) != 2) return false;
    void *contents = nullptr;
    return SettingsRowIndex(dropdown, &contents) >= 0 && [ui.settingsTitle(contents) isEqualToString:@"MetalFX"];
}

NSString *RenderLabel(size_t index) {
    return (@[useChineseLabels ? @"默认" : @"Default", @"0.6", @"0.8", @"1.0"])[index];
}

NSString *MetalLabel(MetalMode mode) {
    NSArray<NSString *> *labels = useChineseLabels ? @[@"关闭", @"Spatial（推荐）", @"Temporal（实验性）"]
                                                  : @[@"Off", @"Spatial (Recommended)", @"Temporal (Experimental)"];
    return labels[static_cast<size_t>(mode)];
}

void *NewString(NSString *text) {
    return Unity<void *(*)(const char *)>(stringNewAddress)(text.UTF8String);
}

NSString *UnityUi::settingsTitle(void *contents) {
    if (!contents) return nil;
    if (!findTransform.code && !findTransform.resolve(ManagedClass(UnityCore, "UnityEngine", "Transform"), "Find", 1))
        return nil;
    if (!gameObject.code && !gameObject.resolve(ManagedClass(UnityCore, "UnityEngine", "Component"), "get_gameObject", 0))
        return nil;
    if (!componentByName.code &&
        !componentByName.resolve(ManagedClass(UnityCore, "UnityEngine", "GameObject"), "GetComponentByName", 1)) return nil;
    if (!textValue.code && !textValue.resolve(ManagedClass("UnityEngine.UI.dll", "UnityEngine.UI", "Text"), "get_text", 0))
        return nil;

    void *title = findTransform.code(contents, NewString(@"Title/TextTitle"), findTransform.method);
    if (!title) return nil;
    void *object = gameObject.code(title, gameObject.method);
    if (!object) return nil;
    void *label = componentByName.code(object, NewString(@"Text"), componentByName.method);
    return label ? ManagedString(textValue.code(label, textValue.method)) : nil;
}

void CheckMetalSupport() {
    metalSupportChecked = true;
    ManagedCall<bool (*)(void *)> support;
    nativeMetalSupported = support.resolve(ManagedClass(UnityCore, "UnityEngine", "SystemInfo"), "get_supportMetalFX", 0) &&
                           support.code(support.method);
    NSLog(@"[StarRailDesktopMode] game MetalFX support=%d", nativeMetalSupported);
    if (!nativeMetalSupported) return;

    temporalAvailable = SRDMInstallTemporalMetalFX();
    const NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:MetalPreference];
    if (saved == static_cast<NSInteger>(MetalMode::Spatial)) metalMode = MetalMode::Spatial;
    if (saved == static_cast<NSInteger>(MetalMode::Temporal)) {
        metalMode = temporalAvailable ? MetalMode::Temporal : MetalMode::Spatial;
    }
    SRDMSetTemporalMetalFX(metalMode == MetalMode::Temporal);
}

CGSize GameOutput() {
    const CGSize drawable = SRDMGameDrawableSize();
    if (drawable.width > 0 && drawable.height > 0) return drawable;
    return CGSizeMake(Unity<int (*)(void *)>(addresses->screenWidth)(nullptr),
                      Unity<int (*)(void *)>(addresses->screenHeight)(nullptr));
}

void SetText(void *text, NSString *caption) {
    if (!text || [ManagedString(Field<void *>(text, 0xf0)) isEqualToString:caption]) return;
    void *managed = NewString(caption);
    if (managed) Unity<void (*)(void *, void *, void *)>(addresses->textSet)(text, managed, nullptr);
}

void SetCaption(void *dropdown, NSString *caption) {
    SetText(Field<void *>(dropdown, 0x110), caption);
}

void UpdateResolution(void *dropdown, CGSize output) {
    if (output.width < 1 || output.height < 1) return;
    resolutionRow = dropdown;
    shownResolution = output;
    SetCaption(dropdown, [NSString stringWithFormat:@"%.0fx%.0f", output.width, output.height]);
}

void RefreshDesktopCaption(void *dropdown) {
    if (IsResolutionRow(dropdown)) UpdateResolution(dropdown, GameOutput());
    else if (IsRenderScaleRow(dropdown)) SetCaption(dropdown, RenderLabel(renderSelection));
    else if (IsMetalRow(dropdown)) SetCaption(dropdown, MetalLabel(metalMode));
}

void Refresh(void *dropdown, void *method) {
    originalRefresh(dropdown, method);
    RefreshDesktopCaption(dropdown);
}

void SetValue(void *dropdown, int value, void *method) {
    if (selectingScale == dropdown) {
        if (value >= 0 && static_cast<size_t>(value) < RenderRatios.size()) {
            renderSelection = static_cast<size_t>(value);
            [NSUserDefaults.standardUserDefaults setInteger:value forKey:ScalePreference];
            SetCaption(dropdown, RenderLabel(renderSelection));
        }
        return;
    }
    if (selectingMetal == dropdown) {
        if (value >= 0 && value <= static_cast<int>(temporalAvailable ? MetalMode::Temporal : MetalMode::Spatial)) {
            metalMode = static_cast<MetalMode>(value);
            SRDMSetTemporalMetalFX(metalMode == MetalMode::Temporal);
            [NSUserDefaults.standardUserDefaults setInteger:value forKey:MetalPreference];
            SetCaption(dropdown, MetalLabel(metalMode));
        }
        return;
    }
    originalSetValue(dropdown, value, method);
    RefreshDesktopCaption(dropdown);
}

bool ShowRenderScale(void *dropdown, void *method) {
    constexpr size_t Count = RenderRatios.size();
    std::array<void *, Count> options{}, saved{}, labels{};
    void *list = OptionList(dropdown);
    for (size_t i = 0; i < Count; ++i) {
        options[i] = Option(list, i);
        labels[i] = NewString(RenderLabel(i));
        if (!options[i] || !labels[i]) return false;
        saved[i] = Field<void *>(options[i], 0x10);
    }
    const auto setText = Unity<void (*)(void *, void *, void *)>(addresses->optionTextSet);
    int &count = Field<int>(list, 0x18);
    int &value = Field<int>(dropdown, 0x130);
    const int oldCount = count;
    const int oldValue = value;
    for (size_t i = 0; i < Count; ++i) setText(options[i], labels[i], nullptr);
    count = Count;
    value = static_cast<int>(renderSelection);
    originalShow(dropdown, method);
    value = oldValue;
    count = oldCount;
    for (size_t i = 0; i < Count; ++i) setText(options[i], saved[i], nullptr);
    SetCaption(dropdown, RenderLabel(renderSelection));
    return true;
}

struct Vector3 { float x, y, z; };
struct Rect { float x, y, width, height; };

void PlaceMetalPopupAbove(void *dropdown, void *lastItem) {
    void *popup = Field<void *>(dropdown, 0x158);
    if (!popup || !lastItem) return;
    const auto getRect = Unity<Rect(*)(void *)>(addresses->rect);
    const auto transformPoint = Unity<Vector3(*)(void *, Vector3)>(addresses->transformPoint);
    const auto getPosition = Unity<Vector3(*)(void *)>(addresses->position);
    const auto setPosition = Unity<void(*)(void *, Vector3)>(addresses->setPosition);
    const auto componentTransform = Unity<UnityUi::Receiver>(addresses->componentTransform);
    void *popupTransform = Unity<UnityUi::Receiver>(addresses->gameObjectTransform)(popup, nullptr);
    void *sourceTransform = componentTransform(dropdown, nullptr);
    void *lastTransform = Field<void *>(lastItem, 0x28);
    if (!popupTransform || !sourceTransform || !lastTransform) return;

    // The clone's RectTransform can be taller than its populated list.
    // Align the visible last item with the top edge of the MetalFX row.
    const Rect source = getRect(sourceTransform);
    const Rect last = getRect(lastTransform);
    if (!(source.height > 0 && last.height > 0)) return;
    const auto sourceTop = transformPoint(sourceTransform, {0, source.y + source.height + 2, 0});
    const auto lastBottom = transformPoint(lastTransform, {0, last.y, 0});
    auto position = getPosition(popupTransform);
    position.y += sourceTop.y - lastBottom.y;
    setPosition(popupTransform, position);
}

void FinishMetalPopup(void *dropdown, int count) {
    void *items = Field<void *>(dropdown, 0x168);
    if (!items || Field<int>(items, 0x18) != count) return;
    for (int i = 0; i < count; ++i) {
        void *item = Option(items, i);
        if (item) SetText(Field<void *>(item, 0x18), MetalLabel(static_cast<MetalMode>(i)));
    }
    PlaceMetalPopupAbove(dropdown, Option(items, count - 1));
}

bool ShowMetal(void *dropdown, void *method) {
    void *list = OptionList(dropdown);
    void *oldItems = Field<void *>(list, 0x10);
    void *first = Option(list, 0);
    void *second = Option(list, 1);
    if (!oldItems || !first || !second) return false;
    const int count = temporalAvailable ? 3 : 2;
    const auto allocateArray = Unity<void *(*)(void *, unsigned)>(addresses->allocateArray);
    const auto assign = Unity<void (*)(void *, void **, void *)>(addresses->writeBarrier);
    void *array = allocateArray(Field<void *>(oldItems, 0), count);
    if (!array || Field<size_t>(array, 0x18) != static_cast<size_t>(count)) return false;
    // The native Show builds a distinct toggle for each position. The options
    // supply the localized item template, and the finished toggles get our labels.
    assign(array, &Field<void *>(array, 0x20), first);
    assign(array, &Field<void *>(array, 0x28), second);
    if (count == 3) assign(array, &Field<void *>(array, 0x30), second);
    int &size = Field<int>(list, 0x18);
    int &value = Field<int>(dropdown, 0x130);
    const int oldSize = size;
    const int oldValue = value;
    assign(list, &Field<void *>(list, 0x10), array);
    size = count;
    value = static_cast<int>(metalMode);
    originalShow(dropdown, method);
    value = oldValue;
    size = oldSize;
    assign(list, &Field<void *>(list, 0x10), oldItems);
    FinishMetalPopup(dropdown, count);
    SetCaption(dropdown, MetalLabel(metalMode));
    return true;
}

void Show(void *dropdown, void *method) {
    if (IsResolutionRow(dropdown)) {
        UpdateResolution(dropdown, GameOutput());
        return;
    }
    if (IsRenderScaleRow(dropdown) && ShowRenderScale(dropdown, method)) return;
    if (IsMetalRow(dropdown) && ShowMetal(dropdown, method)) return;
    originalShow(dropdown, method);
}

void Select(void *dropdown, void *item, void *method) {
    if (IsResolutionRow(dropdown)) return;
    void *previousScale = selectingScale;
    void *previousMetal = selectingMetal;
    if (IsRenderScaleRow(dropdown)) selectingScale = dropdown;
    else if (IsMetalRow(dropdown)) selectingMetal = dropdown;
    originalSelect(dropdown, item, method);
    selectingScale = previousScale;
    selectingMetal = previousMetal;
}

void BuildPostProcessing(void *renderer, void *commands, void *method) {
    auto *pipeline = nativeMetalSupported ? Unity<void *(*)()>(addresses->activePipeline)() : nullptr;
    void *quality = pipeline ? Field<void *>(pipeline, 0x38) : nullptr;
    if (!quality) {
        originalBuildPostProcessing(renderer, commands, method);
        return;
    }
    uint8_t &enableSpatial = Field<uint8_t>(quality, 0x1f);
    const uint8_t native = enableSpatial;
    enableSpatial = metalMode != MetalMode::Off;
    originalBuildPostProcessing(renderer, commands, method);
    enableSpatial = native;
}

bool IsMainCamera(void *camera) {
    return camera && ui.resolve() && [ui.name(camera) isEqualToString:@"MainCamera"];
}

void ConfigureCameraScale(void *cameraData, void *method) {
    const float requested = RenderRatios[renderSelection];
    if (requested == 0 || !cameraData || !IsMainCamera(Field<void *>(cameraData, 0x40))) {
        originalConfigureCameraScale(cameraData, method);
        return;
    }
    auto *pipeline = Unity<void *(*)()>(addresses->activePipeline)();
    if (!pipeline) {
        originalConfigureCameraScale(cameraData, method);
        return;
    }
    float &scale = Field<float>(pipeline, 0x20);
    const float native = scale;
    scale = requested;
    originalConfigureCameraScale(cameraData, method);
    scale = native;
}

void ApplyCameraSettings(void *renderer, void *camera, void *settings, void *method) {
    const float requested = RenderRatios[renderSelection];
    if (requested == 0 || !settings || Field<uint8_t>(settings, 0) != 1 || !IsMainCamera(camera)) {
        originalApply(renderer, camera, settings, method);
        return;
    }

    const auto validDimension = [](int value) { return value >= 32 && value <= 8192; };
    const int width = Field<int>(settings, 4);
    const int height = Field<int>(settings, 8);
    auto *pipeline = Unity<void *(*)()>(addresses->activePipeline)();
    if (!pipeline || !validDimension(width) || !validDimension(height)) {
        originalApply(renderer, camera, settings, method);
        return;
    }
    float &pipelineRatio = Field<float>(pipeline, 0x20);
    const float nativeRatio = pipelineRatio;
    int &sceneWidth = Field<int>(settings, 0xc);
    int &sceneHeight = Field<int>(settings, 0x10);
    const int nativeWidth = sceneWidth;
    const int nativeHeight = sceneHeight;
    if (!(nativeRatio >= 0.25f && nativeRatio <= 2.f) ||
        !validDimension(nativeWidth) || !validDimension(nativeHeight)) {
        originalApply(renderer, camera, settings, method);
        return;
    }

    // Use Unity's own rounding so the renderer descriptor and its camera input agree.
    const auto round = Unity<int (*)(float)>(addresses->roundSceneDimension);
    const int requestedWidth = round(width * requested);
    const int requestedHeight = round(height * requested);
    pipelineRatio = requested;
    sceneWidth = requestedWidth;
    sceneHeight = requestedHeight;
    originalApply(renderer, camera, settings, method);
    sceneWidth = nativeWidth;
    sceneHeight = nativeHeight;
    pipelineRatio = nativeRatio;
}

void Disable(void *dropdown, void *method) {
    if (resolutionRow == dropdown) resolutionRow = nullptr;
    originalDisable(dropdown, method);
}

} // namespace

bool SRDMInstallGraphicsSettings(const mach_header_64 &header, intptr_t slide, const starrail::ClientProfile &client) {
    const auto *text = SRDMFindSection(header, "__TEXT", "__text");
    if (!starrail::CheckStringAllocator(text, slide, client)) return false;
    unitySlide = slide;
    unityText = text;
    stringNewAddress = client.stringNew;
    const bool international = client.region == starrail::ClientRegion::international;
    addresses = international ? &InternationalGraphics : &MainlandGraphics;
    NSString *language = NSProcessInfo.processInfo.environment[@"POMPOMIA_UI_LANGUAGE"];
    useChineseLabels = language ? [language isEqualToString:@"zh-Hans"] : !international;
    const NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:ScalePreference];
    if (saved >= 0 && static_cast<size_t>(saved) < RenderRatios.size()) renderSelection = saved;

    using Hook = starrail::UnityCodeHook;
    std::array hooks{
        Hook(addresses->refresh, {0xd10103ff, 0xa90157f6, 0xa9024ff4, 0xa9037bfd}, (uintptr_t)Refresh),
        Hook(addresses->show, {0xd105c3ff, 0x6d0f2beb, 0x6d1023e9, 0xa9116ffc}, (uintptr_t)Show),
        Hook(addresses->setValue, {0xd100c3ff, 0xa9014ff4, 0xa9027bfd, 0x910083fd}, (uintptr_t)SetValue),
        Hook(addresses->disable, {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd}, (uintptr_t)Disable),
        Hook(addresses->select, {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd}, (uintptr_t)Select),
        Hook(addresses->applyCamera, {0xd10143ff, 0xa9015ff8, 0xa90257f6, 0xa9034ff4}, (uintptr_t)ApplyCameraSettings),
        Hook(addresses->buildPostProcessing, {0xd10683ff, 0x6d122beb, 0x6d1323e9, 0xa9146ffc}, (uintptr_t)BuildPostProcessing),
        Hook(addresses->configureCamera, {0xa9bb67fa, 0xa9015ff8, 0xa90257f6, 0xa9034ff4},
             (uintptr_t)ConfigureCameraScale),
    };
    for (auto &hook : hooks) {
        if (hook.prepare(*text, slide)) continue;
        for (auto &prepared : hooks) prepared.release();
        return false;
    }
    originalRefresh = hooks[0].original<DropdownMethod>();
    originalShow = hooks[1].original<DropdownMethod>();
    originalSetValue = hooks[2].original<SetValueMethod>();
    originalDisable = hooks[3].original<DropdownMethod>();
    originalSelect = hooks[4].original<SelectMethod>();
    originalApply = hooks[5].original<ApplyMethod>();
    originalBuildPostProcessing = hooks[6].original<BuildPostProcessingMethod>();
    originalConfigureCameraScale = hooks[7].original<DropdownMethod>();
    size_t count = 0;
    for (; count < hooks.size(); ++count) {
        if (hooks[count].install()) continue;
        const size_t failed = count;
        while (count > 0) {
            auto &hook = hooks[--count];
            if (hook.restore()) hook.release();
        }
        for (size_t i = failed; i < hooks.size(); ++i) hooks[i].release();
        return false;
    }
    installed = true;
    return true;
}

void SRDMUpdateGraphicsSettings() {
    if (!installed) return;
    if (!metalSupportChecked && SRDMGameDrawableSize().width > 0) CheckMetalSupport();
    if (!resolutionRow) return;
    const CGSize output = GameOutput();
    if (!CGSizeEqualToSize(shownResolution, output)) UpdateResolution(resolutionRow, output);
}
