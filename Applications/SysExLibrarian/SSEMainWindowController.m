#import "SSEMainWindowController.h"

#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

#import "NSPopUpButton-Extensions.h"
#import "SSEDeleteController.h"
#import "SSEDetailsWindowController.h"
#import "SSEFindMissingController.h"
#import "SSEImportController.h"
#import "SSELibrary.h"
#import "SSELibraryEntry.h"
#import "SSEMIDIController.h"
#import "SSEPlayController.h"
#import "SSEPreferencesWindowController.h"
#import "SSERecordOneController.h"
#import "SSERecordManyController.h"
#import "SSETableView.h"


@interface SSEMainWindowController (Private)

- (void)_displayPreferencesDidChange:(NSNotification *)notification;

- (BOOL)_finishEditingResultsInError;

- (void)_synchronizeDestinationPopUpWithDescriptions:(NSArray *)descriptions currentDescription:(NSDictionary *)currentDescription;
- (void)_synchronizeDestinationToolbarMenuWithDescriptions:(NSArray *)descriptions currentDescription:(NSDictionary *)currentDescription;

- (void)_libraryDidChange:(NSNotification *)notification;
- (void)_sortLibraryEntries;

- (NSArray *)_selectedEntries;
- (void)_selectEntries:(NSArray *)entries;
- (void)_scrollToEntries:(NSArray *)entries;

- (void)_playSelectedEntries;
- (void)_showDetailsOfSelectedEntries;

- (void)_openPanelDidEnd:(NSOpenPanel *)openPanel returnCode:(int)returnCode contextInfo:(void *)contextInfo;

- (BOOL)_areAnyFilesAcceptableForImport:(NSArray *)filePaths;

- (void)_findMissingFilesAndPerformSelector:(SEL)selector;

@end


@implementation SSEMainWindowController

NSString *SSEAbbreviateFileSizesInLibraryTableViewPreferenceKey = @"SSEAbbreviateFileSizesInLibraryTableView";

static SSEMainWindowController *controller;


+ (SSEMainWindowController *)mainWindowController;
{
    if (!controller)
        controller = [[self alloc] init];

    return controller;
}

- (id)init;
{
    if (!(self = [super initWithWindowNibName:@"MainWindow"]))
        return nil;

    library = [[SSELibrary sharedLibrary] retain];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_libraryDidChange:) name:SSELibraryDidChangeNotification object:library];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_displayPreferencesDidChange:) name:SSEDisplayPreferenceChangedNotification object:nil];

    midiController = [[SSEMIDIController alloc] initWithWindowController:self];
    
    sortColumnIdentifier = @"name";
    isSortAscending = YES;

    showSysExWarningWhenShowingWindow = NO;

    return self;
}

- (id)initWithWindowNibName:(NSString *)windowNibName;
{
    OBRejectUnusedImplementation(self, _cmd);
    return nil;
}

- (void)dealloc
{
    [midiController release];
    midiController = nil;    
    [playController release];
    playController = nil;
    [recordOneController  release];
    recordOneController = nil;
    [recordManyController release];
    recordManyController = nil;
    [deleteController release];
    deleteController = nil;
    [importController release];
    importController = nil;
    [sortColumnIdentifier release];
    sortColumnIdentifier = nil;
    [sortedLibraryEntries release];
    sortedLibraryEntries = nil;
    
    [super dealloc];
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    [libraryTableView registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
    [libraryTableView setTarget:self];
    [libraryTableView setDoubleAction:@selector(play:)];
}

- (void)windowDidLoad
{
    [super windowDidLoad];

    [self synchronizeInterface];
}

- (void)speciallyInitializeToolbarItem:(NSToolbarItem *)toolbarItem;
{
    float height;
    NSMenuItem *menuItem;
    NSMenu *submenu;

    nonretainedDestinationToolbarItem = toolbarItem;
    
    [toolbarItem setView:destinationPopUpButton];

    height = NSHeight([destinationPopUpButton frame]);
    [toolbarItem setMinSize:NSMakeSize(150, height)];
    [toolbarItem setMaxSize:NSMakeSize(1000, height)];

    menuItem = [[NSMenuItem alloc] initWithTitle:@"Destination" action:NULL keyEquivalent:@""];
    submenu = [[NSMenu alloc] initWithTitle:@""];
    [menuItem setSubmenu:submenu];
    [submenu release];
    [toolbarItem setMenuFormRepresentation:menuItem];
    [menuItem release];
}

- (IBAction)showWindow:(id)sender;
{
    [super showWindow:sender];

    if (showSysExWarningWhenShowingWindow) {
        [self showSysExWorkaroundWarning];
        showSysExWarningWhenShowingWindow = NO;
    }
}

//
// Action validation
//

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)theItem;
{
    SEL action;

    action = [theItem action];

    if (action == @selector(play:))
        return ([libraryTableView numberOfSelectedRows] > 0);
    else if (action == @selector(delete:))
        return ([libraryTableView numberOfSelectedRows] > 0);
    else if (action == @selector(showFileInFinder:))
        return ([libraryTableView numberOfSelectedRows] == 1 && [[[self _selectedEntries] objectAtIndex:0] isFilePresent]);
    else if (action == @selector(rename:))
        return ([libraryTableView numberOfSelectedRows] == 1 && [[[self _selectedEntries] objectAtIndex:0] isFilePresent]);
    else if (action == @selector(showDetails:))
        return ([libraryTableView numberOfSelectedRows] > 0);
    else
        return [super validateUserInterfaceItem:theItem];
}

//
// Actions
//

- (IBAction)selectDestinationFromPopUpButton:(id)sender;
{
    [midiController setDestinationDescription:[(NSMenuItem *)[sender selectedItem] representedObject]];
}

- (IBAction)selectDestinationFromMenuItem:(id)sender;
{
    [midiController setDestinationDescription:[(NSMenuItem *)sender representedObject]];
}

- (IBAction)selectAll:(id)sender;
{
    // Forward to the library table view, even if it isn't the first responder
    [libraryTableView selectAll:sender];
}

- (IBAction)addToLibrary:(id)sender;
{
    NSOpenPanel *openPanel;

    if ([self _finishEditingResultsInError])
        return;
    
    openPanel = [NSOpenPanel openPanel];
    [openPanel setAllowsMultipleSelection:YES];

    [openPanel beginSheetForDirectory:nil file:nil types:[library allowedFileTypes] modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_openPanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
}

- (IBAction)delete:(id)sender;
{
    if ([self _finishEditingResultsInError])
        return;

    if (!deleteController)
        deleteController = [[SSEDeleteController alloc] initWithWindowController:self];

    [deleteController deleteEntries:[self _selectedEntries]];
}

- (IBAction)recordOne:(id)sender;
{
    if ([self _finishEditingResultsInError])
        return;

    if (!recordOneController)
        recordOneController = [[SSERecordOneController alloc] initWithMainWindowController:self midiController:midiController];

    [recordOneController beginRecording];    
}

- (IBAction)recordMany:(id)sender;
{
    if ([self _finishEditingResultsInError])
        return;

    if (!recordManyController)
        recordManyController = [[SSERecordManyController alloc] initWithMainWindowController:self midiController:midiController];

    [recordManyController beginRecording];
}

- (IBAction)play:(id)sender;
{
    if ([self _finishEditingResultsInError])
        return;

    [self _findMissingFilesAndPerformSelector:@selector(_playSelectedEntries)];
}

- (IBAction)showFileInFinder:(id)sender;
{
    NSArray *selectedEntries;
    NSString *path;

    [self finishEditingInWindow];
        // We don't care if there is an error, go on anyway

    selectedEntries = [self _selectedEntries];
    OBASSERT([selectedEntries count] == 1);

    if ((path = [[selectedEntries objectAtIndex:0] path]))
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    else
        NSBeep();	// Turns out the file isn't there after all
}

- (IBAction)rename:(id)sender;
{
    if ([libraryTableView editedRow] >= 0) {
        // We are already editing the table view, so don't do anything
    } else  {
        [self finishEditingInWindow];  // In case we are editing something else

        // Make sure that the file really exists right now before we try to rename it
        if ([[[self _selectedEntries] objectAtIndex:0] isFilePresentIgnoringCachedValue])
            [libraryTableView editColumn:0 row:[libraryTableView selectedRow] withEvent:nil select:YES];
        else
            NSBeep();
    }
}

- (IBAction)showDetails:(id)sender;
{
    if ([self _finishEditingResultsInError])
        return;

    [self _findMissingFilesAndPerformSelector:@selector(_showDetailsOfSelectedEntries)];
}

//
// Other API
//

- (void)synchronizeInterface;
{
    [self synchronizeDestinations];
    [self synchronizeLibrarySortIndicator];
    [self synchronizeLibrary];
}

- (void)synchronizeDestinations;
{
    NSArray *descriptions;
    NSDictionary *currentDescription;

    descriptions = [midiController destinationDescriptions];
    currentDescription = [midiController destinationDescription];

    [self _synchronizeDestinationPopUpWithDescriptions:descriptions currentDescription:currentDescription];
    [self _synchronizeDestinationToolbarMenuWithDescriptions:descriptions currentDescription:currentDescription];
}

- (void)synchronizeLibrarySortIndicator;
{
    NSTableColumn *column;

    column = [libraryTableView tableColumnWithIdentifier:sortColumnIdentifier];    
    [libraryTableView setSortColumn:column isAscending:isSortAscending];
    [libraryTableView setHighlightedTableColumn:column];
}

- (void)synchronizeLibrary;
{
    NSArray *selectedEntries;

    selectedEntries = [self _selectedEntries];

    [self _sortLibraryEntries];

    // NOTE Some entries in selectedEntries may no longer be present in sortedLibraryEntries.
    // We don't need to manually take them out of selectedEntries because _selectEntries can deal with
    // entries that are missing.
    
    [libraryTableView reloadData];
    [self _selectEntries:selectedEntries];

    // Sometimes, apparently, reloading the table view will not mark the window as needing update. Weird.
    [NSApp setWindowsNeedUpdate:YES];
}

- (void)importFiles:(NSArray *)filePaths showingProgress:(BOOL)showProgress;
{
    if (!importController)
        importController = [[SSEImportController alloc] initWithWindowController:self];

    [importController importFiles:filePaths showingProgress:showProgress];
}

- (void)showNewEntries:(NSArray *)newEntries;
{
    [self synchronizeLibrary];
    [self _selectEntries:newEntries];
    [self _scrollToEntries:newEntries];
}

- (void)addReadMessagesToLibrary;
{
    NSData *allSysexData;
    SSELibraryEntry *entry = nil;
    NSString *exceptionReason = nil;

    allSysexData = [SMSystemExclusiveMessage dataForSystemExclusiveMessages:[midiController messages]];
    if (!allSysexData)
        return;	// No messages, no data, nothing to do
    
    NS_DURING {
        entry = [library addNewEntryWithData:allSysexData];
    } NS_HANDLER {
        exceptionReason = [[[localException reason] retain] autorelease];
    } NS_ENDHANDLER;

    if (entry) {
        [self showNewEntries:[NSArray arrayWithObject:entry]];
    } else {
        NSWindow *attachedSheet;
        
        if (!exceptionReason)
            exceptionReason = @"Unknown error";   // NOTE I don't see how this could happen, but let's handle it...

        // We need to get rid of the sheet right away, instead of after the delay (see -[SSERecordOneController readFinished]).
        if ((attachedSheet = [[self window] attachedSheet])) {
            [NSObject cancelPreviousPerformRequestsWithTarget:NSApp selector:@selector(endSheet:) object:attachedSheet];
            [NSApp endSheet:attachedSheet];
        }

        // Now we can start another sheet.
        OBASSERT([[self window] attachedSheet] == nil);
        NSBeginAlertSheet(@"Error", nil, nil, nil, [self window], nil, NULL, NULL, NULL, @"The file could not be created.\n%@", exceptionReason);
    }
}

- (void)showSysExWorkaroundWarning;
{    
    if (![[self window] isVisible]) {
        showSysExWarningWhenShowingWindow = YES;
        return;
    }
    
    OBASSERT([[self window] attachedSheet] == nil);
    if ([[self window] attachedSheet])
        return;

    NSBeginAlertSheet(@"Warning", nil, nil, nil, [self window], nil, NULL, NULL, NULL, @"The driver for this MIDIMAN device has problems sending SysEx messages. SysEx Librarian will attempt to work around the problems, but please be warned that you may still experience unpredictable hangs or crashes, and sending large amounts of data will be slow.\n\nPlease check the manufacturer's web site to see if an updated driver is available.");

    [[OFPreference preferenceForKey:SSEHasShownSysExWorkaroundWarningPreferenceKey] setBoolValue:YES];
    [[NSUserDefaults standardUserDefaults] autoSynchronize];
}

@end


@implementation SSEMainWindowController (NotificationsDelegatesDataSources)

//
// NSTableView data source
//

- (int)numberOfRowsInTableView:(NSTableView *)tableView;
{
    return [sortedLibraryEntries count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    SSELibraryEntry *entry;
    NSString *identifier;

    entry = [sortedLibraryEntries objectAtIndex:row];
    identifier = [tableColumn identifier];

    if ([identifier isEqualToString:@"name"]) {
        return [entry name];
    } else if ([identifier isEqualToString:@"manufacturer"]) {
        return [entry manufacturer];
    } else if ([identifier isEqualToString:@"size"]) {
        NSNumber *entrySize;

        entrySize = [entry size];
        if ([[OFPreference preferenceForKey:SSEAbbreviateFileSizesInLibraryTableViewPreferenceKey] boolValue])
            return [NSString abbreviatedStringForBytes:[entrySize unsignedIntValue]];
        else
            return [entrySize stringValue];
    } else if ([identifier isEqualToString:@"messageCount"]) {
        return [entry messageCount];
    } else {
        return nil;
    }
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    NSString *newName = (NSString *)object;
    SSELibraryEntry *entry;

    if (!newName || [newName length] == 0)
        return;
    
    entry = [sortedLibraryEntries objectAtIndex:row];
    if (![entry renameFileTo:newName]) {
        NSBeginAlertSheet(@"Error", nil, nil, nil, [self window], nil, NULL, NULL, NULL, @"The file for this item could not be renamed.");
    }
    
    [self synchronizeLibrary];
}

//
// SSETableView data source
//

- (void)tableView:(SSETableView *)tableView deleteRows:(NSArray *)rows;
{
    [self delete:tableView];
}

- (NSDragOperation)tableView:(SSETableView *)tableView draggingEntered:(id <NSDraggingInfo>)sender;
{
    if ([self _areAnyFilesAcceptableForImport:[[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType]])
        return NSDragOperationGeneric;
    else
        return NSDragOperationNone;
}

- (BOOL)tableView:(SSETableView *)tableView performDragOperation:(id <NSDraggingInfo>)sender;
{
    NSArray *filePaths;

    filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    [self importFiles:filePaths showingProgress:YES];

    return YES;
}

//
// NSTableView delegate
//

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    SSELibraryEntry *entry;
    NSColor *color;
    
    entry = [sortedLibraryEntries objectAtIndex:row];
    color = [entry isFilePresent] ? [NSColor blackColor] : [NSColor redColor];
    [cell setTextColor:color];
}

- (void)tableView:(NSTableView *)tableView mouseDownInHeaderOfTableColumn:(NSTableColumn *)tableColumn;
{
    NSString *identifier;

    identifier = [tableColumn identifier];
    if ([identifier isEqualToString:sortColumnIdentifier]) {
        isSortAscending = !isSortAscending;
    } else {
        [sortColumnIdentifier release];
        sortColumnIdentifier = [identifier retain];
        isSortAscending = YES;
    }

    [self synchronizeLibrarySortIndicator];
    [self synchronizeLibrary];
    [self _scrollToEntries:[self _selectedEntries]];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    SSELibraryEntry *entry;

    entry = [sortedLibraryEntries objectAtIndex:row];
    return ([entry isFilePresent]);
}

@end


@implementation SSEMainWindowController (Private)

- (void)_displayPreferencesDidChange:(NSNotification *)notification;
{
    [libraryTableView reloadData];
}

- (BOOL)_finishEditingResultsInError;
{
    [self finishEditingInWindow];
    return ([[self window] attachedSheet] != nil);
}

//
// Destination selections (popup and toolbar menu)
//

- (void)_synchronizeDestinationPopUpWithDescriptions:(NSArray *)descriptions currentDescription:(NSDictionary *)currentDescription;
{
    BOOL wasAutodisplay;
    unsigned int count, index;
    BOOL found = NO;
    BOOL addedSeparatorBetweenPortAndVirtual = NO;
    
    // The pop up button redraws whenever it's changed, so turn off autodisplay to stop the blinkiness
    wasAutodisplay = [[self window] isAutodisplay];
    [[self window] setAutodisplay:NO];

    [destinationPopUpButton removeAllItems];

    count = [descriptions count];
    for (index = 0; index < count; index++) {
        NSDictionary *description;

        description = [descriptions objectAtIndex:index];
        if (!addedSeparatorBetweenPortAndVirtual && [description objectForKey:@"endpoint"] == nil) {
            if (index > 0)
                [destinationPopUpButton addSeparatorItem];
            addedSeparatorBetweenPortAndVirtual = YES;
        }
        [destinationPopUpButton addItemWithTitle:[description objectForKey:@"name"] representedObject:description];

        if (!found && [description isEqual:currentDescription]) {
            [destinationPopUpButton selectItemAtIndex:[destinationPopUpButton numberOfItems] - 1];
            // Don't use index because it may be off by one (because of the separator item)
            found = YES;
        }
    }

    if (!found)
        [destinationPopUpButton selectItem:nil];

    // ...and turn autodisplay on again
    if (wasAutodisplay)
        [[self window] displayIfNeeded];
    [[self window] setAutodisplay:wasAutodisplay];
}

- (void)_synchronizeDestinationToolbarMenuWithDescriptions:(NSArray *)descriptions currentDescription:(NSDictionary *)currentDescription;
{
    // Set the title to "Destination: <Whatever>"
    // Then set up the submenu items
    NSMenuItem *topMenuItem;
    NSString *destinationName;
    NSMenu *submenu;
    unsigned int count, index;
    BOOL found = NO;
    BOOL addedSeparatorBetweenPortAndVirtual = NO;

    topMenuItem = [nonretainedDestinationToolbarItem menuFormRepresentation];
    
    destinationName = [currentDescription objectForKey:@"name"];
    if (!destinationName)
        destinationName = @"None";
    [topMenuItem setTitle:[@"Destination: " stringByAppendingString:destinationName]];

    submenu = [topMenuItem submenu];
    index = [submenu numberOfItems];
    while (index--)
        [submenu removeItemAtIndex:index];

    count = [descriptions count];
    for (index = 0; index < count; index++) {
        NSDictionary *description;
        NSMenuItem *menuItem;

        description = [descriptions objectAtIndex:index];
        if (!addedSeparatorBetweenPortAndVirtual && [description objectForKey:@"endpoint"] == nil) {
            if (index > 0)
                [submenu addItem:[NSMenuItem separatorItem]];
            addedSeparatorBetweenPortAndVirtual = YES;
        }
        menuItem = [submenu addItemWithTitle:[description objectForKey:@"name"] action:@selector(selectDestinationFromMenuItem:) keyEquivalent:@""];
        [menuItem setRepresentedObject:description];
        [menuItem setTarget:self];

        if (!found && [description isEqual:currentDescription]) {
            [menuItem setState:NSOnState];
            found = YES;
        }
    }

    // Workaround to get the toolbar item to refresh after we change the title of the menu item
    [topMenuItem retain];
    [nonretainedDestinationToolbarItem setMenuFormRepresentation:nil];
    [nonretainedDestinationToolbarItem setMenuFormRepresentation:topMenuItem];
    [topMenuItem release];    
}

//
// Library interaction
//

- (void)_libraryDidChange:(NSNotification *)notification;
{
    // Reloading the table view will wipe out the edit session, so don't do that if we're editing
    if ([libraryTableView editedRow] == -1)
        [self synchronizeLibrary];
}

static int libraryEntryComparator(id object1, id object2, void *context)
{
    NSString *key = (NSString *)context;
    id value1, value2;

    value1 = [object1 valueForKey:key];
    value2 = [object2 valueForKey:key];

    if (value1 && value2)
        // NOTE: We would say:
        // return [value1 compare:value2];
        // but that gives us a warning because there are multiple declarations of compare: (for NSString, NSDate, etc.).
        // So let's just avoid that whole problem.
        return (NSComparisonResult)objc_msgSend(value1, @selector(compare:), value2);
    else if (value1) {
        return NSOrderedDescending;
    } else {
        // both are nil
        return NSOrderedSame;
    }
}

- (void)_sortLibraryEntries;
{
    [sortedLibraryEntries release];
    sortedLibraryEntries = [[library entries] sortedArrayUsingFunction:libraryEntryComparator context:sortColumnIdentifier];
    if (!isSortAscending)
        sortedLibraryEntries = [sortedLibraryEntries reversedArray];
    [sortedLibraryEntries retain];
}

- (NSArray *)_selectedEntries;
{
    NSMutableArray *selectedEntries;
    NSEnumerator *selectedRowEnumerator;
    NSNumber *rowNumber;

    selectedEntries = [NSMutableArray array];

    selectedRowEnumerator = [libraryTableView selectedRowEnumerator];
    while ((rowNumber = [selectedRowEnumerator nextObject])) {
        [selectedEntries addObject:[sortedLibraryEntries objectAtIndex:[rowNumber intValue]]];
    }

    return selectedEntries;
}

- (void)_selectEntries:(NSArray *)entries;
{
    unsigned int entryCount, entryIndex;

    [libraryTableView deselectAll:nil];

    entryCount = [entries count];
    if (entryCount == 0)
        return;

    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        unsigned int row;

        row = [sortedLibraryEntries indexOfObjectIdenticalTo:[entries objectAtIndex:entryIndex]];
        if (row != NSNotFound)
            [libraryTableView selectRow:row byExtendingSelection:YES];
    }
}

- (void)_scrollToEntries:(NSArray *)entries;
{
    unsigned int entryCount, entryIndex;
    unsigned int lowestRow = UINT_MAX;

    entryCount = [entries count];
    if (entryCount == 0)
        return;
    
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        unsigned int row;

        row = [sortedLibraryEntries indexOfObjectIdenticalTo:[entries objectAtIndex:entryIndex]];
        if (row != NSNotFound)
            lowestRow = MIN(lowestRow, row);
    }

    [libraryTableView scrollRowToVisible:lowestRow];
}

//
// Doing things with selected entries
//

- (void)_playSelectedEntries;
{
    NSArray *selectedEntries;
    NSMutableArray *messages;
    unsigned int entryCount, entryIndex;

    selectedEntries = [self _selectedEntries];

    messages = [NSMutableArray array];
    entryCount = [selectedEntries count];
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        [messages addObjectsFromArray:[[selectedEntries objectAtIndex:entryIndex] messages]];
    }

    if ([messages count] > 0) {
        if (!playController)
            playController = [[SSEPlayController alloc] initWithWindowController:self midiController:midiController];

        [playController playMessages:messages];
    }
}

- (void)_showDetailsOfSelectedEntries;
{
    NSArray *selectedEntries;
    unsigned int entryCount, entryIndex;

    selectedEntries = [self _selectedEntries];
    entryCount = [selectedEntries count];
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        SSELibraryEntry *entry;

        entry = [selectedEntries objectAtIndex:entryIndex];
        [[SSEDetailsWindowController detailsWindowControllerWithEntry:entry] showWindow:nil];
    }
}

//
// Add files / importing
//

- (void)_openPanelDidEnd:(NSOpenPanel *)openPanel returnCode:(int)returnCode contextInfo:(void  *)contextInfo;
{
    if (returnCode == NSOKButton) {
        [openPanel orderOut:nil];
        [self importFiles:[openPanel filenames] showingProgress:NO];
    }
}

- (BOOL)_areAnyFilesAcceptableForImport:(NSArray *)filePaths;
{
    NSFileManager *fileManager;
    unsigned int fileIndex, fileCount;

    fileManager = [NSFileManager defaultManager];

    fileCount = [filePaths count];
    for (fileIndex = 0; fileIndex < fileCount; fileIndex++) {
        NSString *filePath;
        BOOL isDirectory;

        filePath = [filePaths objectAtIndex:fileIndex];
        if ([fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] == NO)
            continue;

        if (isDirectory)
            return YES;

        if ([fileManager isReadableFileAtPath:filePath] && [library typeOfFileAtPath:filePath] != SSELibraryFileTypeUnknown)
            return YES;
    }

    return NO;
}

//
// Finding missing files
//

- (void)_findMissingFilesAndPerformSelector:(SEL)selector;
{
    NSArray *selectedEntries;
    unsigned int entryCount, entryIndex;
    NSMutableArray *entriesWithMissingFiles;

    selectedEntries = [self _selectedEntries];

    // Which entries can't find their associated file?
    entryCount = [selectedEntries count];
    entriesWithMissingFiles = [NSMutableArray arrayWithCapacity:entryCount];
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        SSELibraryEntry *entry;

        entry = [selectedEntries objectAtIndex:entryIndex];
        if (![entry isFilePresentIgnoringCachedValue])
            [entriesWithMissingFiles addObject:entry];
    }

    if ([entriesWithMissingFiles count] == 0) {
        [self performSelector:selector];
    } else {
        if (!findMissingController)
            findMissingController = [[SSEFindMissingController alloc] initWithWindowController:self];
    
        [findMissingController findMissingFilesForEntries:entriesWithMissingFiles andPerformSelectorOnWindowController:selector];
    }
}

@end
