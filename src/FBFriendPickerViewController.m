/*
 * Copyright 2012 Facebook
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *    http://www.apache.org/licenses/LICENSE-2.0
 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBError.h"
#import "FBFriendPickerViewController.h"
#import "FBFriendPickerViewController+Internal.h"
#import "FBFriendPickerCacheDescriptor.h"
#import "FBGraphObjectPagingLoader.h"
#import "FBGraphObjectTableDataSource.h"
#import "FBGraphObjectTableSelection.h"
#import "FBGraphObjectTableCell.h"
#import "FBLogger.h"
#import "FBRequest.h"
#import "FBRequestConnection.h"
#import "FBUtility.h"
#import "FBSession+Internal.h"
#import "FBSettings.h"

NSString *const FBFriendPickerCacheIdentity = @"FBFriendPicker";
static NSString *defaultImageName = @"FacebookSDKResources.bundle/FBFriendPickerView/images/default.png";

int const FBRefreshCacheDelaySeconds = 2;

@interface FBFriendPickerViewController () <FBGraphObjectSelectionChangedDelegate, 
                                            FBGraphObjectViewControllerDelegate,
                                            FBGraphObjectPagingLoaderDelegate,
                                            UISearchBarDelegate>

@property (nonatomic, retain) FBGraphObjectTableDataSource *dataSource;
@property (nonatomic, retain) FBGraphObjectTableSelection *selectionManager;
@property (nonatomic, retain) FBGraphObjectPagingLoader *loader;
@property (nonatomic) BOOL trackActiveSession;

- (void)initialize;
- (void)centerAndStartSpinner;
- (void)loadDataSkippingRoundTripIfCached:(NSNumber*)skipRoundTripIfCached;
- (FBRequest*)requestForLoadData;
- (void)addSessionObserver:(FBSession*)session;
- (void)removeSessionObserver:(FBSession*)session;
- (void)clearData;

@end

@implementation FBFriendPickerViewController {
    BOOL _allowsMultipleSelection;
}

@synthesize dataSource = _dataSource;
@synthesize delegate = _delegate;
@synthesize fieldsForRequest = _fieldsForRequest;
@synthesize selectionManager = _selectionManager;
@synthesize spinner = _spinner;
@synthesize tableView = _tableView;
@synthesize searchBar = _searchBar;
@synthesize userID = _userID;
@synthesize loader = _loader;
@synthesize sortOrdering = _sortOrdering;
@synthesize displayOrdering = _displayOrdering;
@synthesize trackActiveSession = _trackActiveSession;
@synthesize session = _session;

- (id)init {
    self = [super init];

    if (self) {
        [self initialize];
    }
    
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    
    if (self) {
        [self initialize];
    }
    
    return self;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];

    if (self) {
        [self initialize];
    }
    
    return self;
}

- (void)initialize {
    // Data Source
    FBGraphObjectTableDataSource *dataSource = [[[FBGraphObjectTableDataSource alloc]
                                                 init]
                                                autorelease];
    dataSource.defaultPicture = [UIImage imageNamed:defaultImageName];
    dataSource.controllerDelegate = self;
    dataSource.itemTitleSuffixEnabled = YES;
    
    // Selection Manager
    FBGraphObjectTableSelection *selectionManager = [[[FBGraphObjectTableSelection alloc]
                                                      initWithDataSource:dataSource]
                                                     autorelease];
    selectionManager.delegate = self;

    // Paging loader
    id loader = [[[FBGraphObjectPagingLoader alloc] initWithDataSource:dataSource
                                                            pagingMode:FBGraphObjectPagingModeImmediate]
                 autorelease];
    self.loader = loader;
    self.loader.delegate = self;

    // Self
    self.allowsMultipleSelection = YES;
    self.dataSource = dataSource;
    self.delegate = nil;
    self.itemPicturesEnabled = YES;
    self.selectionManager = selectionManager;
    self.userID = @"me";
    self.sortOrdering = FBFriendSortByFirstName;
    self.displayOrdering = FBFriendDisplayByFirstName;
    self.trackActiveSession = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [_loader cancel];
    _loader.delegate = nil;
    [_loader release];

    _dataSource.controllerDelegate = nil;
    
    [_dataSource release];
    [_fieldsForRequest release];
    [_selectionManager release];
    [_spinner release];
    [_tableView release];
    [_searchBar release];
    [_userID release];
    
    [self removeSessionObserver:_session];
    [_session release];
    
    [super dealloc];
}

#pragma mark - Custom Properties

- (BOOL)allowsMultipleSelection {
    return _allowsMultipleSelection;
}

- (void)setAllowsMultipleSelection:(BOOL)allowsMultipleSelection {
    _allowsMultipleSelection = allowsMultipleSelection;
    if (self.selectionManager) {
        self.selectionManager.allowsMultipleSelection = allowsMultipleSelection;
    }
}

- (BOOL)itemPicturesEnabled {
    return self.dataSource.itemPicturesEnabled;
}

- (void)setItemPicturesEnabled:(BOOL)itemPicturesEnabled {
    self.dataSource.itemPicturesEnabled = itemPicturesEnabled;
}

- (NSArray *)selection {
    return self.selectionManager.selection;
}

// We don't really need to store session, let the loader hold it.
- (void)setSession:(FBSession *)session {
    if (session != _session) {
        [self removeSessionObserver:_session];
        
        [_session release];
        _session = [session retain];
        
        [self addSessionObserver:session];
        
        self.loader.session = session;
        
        self.trackActiveSession = (session == nil);
    }
}


#pragma mark - Public Methods

- (void)viewDidLoad
{
    [super viewDidLoad];
    [FBLogger registerCurrentTime:FBLoggingBehaviorPerformanceCharacteristics
                          withTag:self];
    CGRect bounds = self.canvasView.bounds;

    if (!self.searchBar) {
        UISearchBar *searchBar = [[[UISearchBar alloc] initWithFrame:CGRectMake(0.0f, 0.0f, bounds.size.width, 44.0f)] autorelease];
        searchBar.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        searchBar.delegate = self;
        searchBar.showsCancelButton = YES;
        
        self.searchBar = searchBar;
        [self.canvasView addSubview:searchBar];
    }

    if (!self.tableView) {
        CGRect tableViewFrame = bounds;
        tableViewFrame.origin.y = 44.0f;
        tableViewFrame.size.height -= 44.0f;
        UITableView *tableView = [[[UITableView alloc] initWithFrame:tableViewFrame] autorelease];
        tableView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        self.tableView = tableView;
        [self.canvasView addSubview:tableView];
    }

    if (!self.spinner) {
        UIActivityIndicatorView *spinner = [[[UIActivityIndicatorView alloc]
                                             initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray]
                                            autorelease];
        spinner.hidesWhenStopped = YES;
        // We want user to be able to scroll while we load.
        spinner.userInteractionEnabled = NO;
        
        self.spinner = spinner;
        [self.canvasView addSubview:spinner];
    }

    self.selectionManager.allowsMultipleSelection = self.allowsMultipleSelection;
    self.tableView.delegate = self.selectionManager;
    [self.dataSource bindTableView:self.tableView];
    self.loader.tableView = self.tableView;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewDidUnload {
    [super viewDidUnload];

    self.loader.tableView = nil;
    self.spinner = nil;
    self.tableView = nil;
}

- (void)configureUsingCachedDescriptor:(FBCacheDescriptor*)cacheDescriptor {
    if (![cacheDescriptor isKindOfClass:[FBFriendPickerCacheDescriptor class]]) {
        [[NSException exceptionWithName:FBInvalidOperationException
                                 reason:@"FBFriendPickerViewController: An attempt was made to configure "
                                        @"an instance with a cache descriptor object that was not created "
                                        @"by the FBFriendPickerViewController class"
                               userInfo:nil]
         raise];
    }
    FBFriendPickerCacheDescriptor *cd = (FBFriendPickerCacheDescriptor*)cacheDescriptor;
    self.userID = cd.userID;
    self.fieldsForRequest = cd.fieldsForRequest;
}

- (void)loadData {
    // when the app calls loadData,
    // if we don't have a session and there is 
    // an open active session, use that
    if (!self.session || 
        (self.trackActiveSession && ![self.session isEqual:[FBSession activeSessionIfOpen]])) {
        self.session = [FBSession activeSessionIfOpen];
        self.trackActiveSession = YES;
    }
    [self loadDataSkippingRoundTripIfCached:[NSNumber numberWithBool:YES]];
}

- (void)updateView {
    [self.dataSource update];
    [self.tableView reloadData];
}

- (void)clearSelection {
    [self.selectionManager clearSelectionInTableView:self.tableView];
}

- (void)addSessionObserver:(FBSession *)session {
    [session addObserver:self
              forKeyPath:@"state"
                 options:NSKeyValueObservingOptionNew
                 context:nil];
}

- (void)removeSessionObserver:(FBSession *)session {    
    [session removeObserver:self
                 forKeyPath:@"state"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath 
                      ofObject:(id)object 
                        change:(NSDictionary *)change 
                       context:(void *)context {
    if ([object isEqual:self.session] &&
        self.session.isOpen == NO) {
        [self clearData];
    }
}

- (void)clearData {
    [self.dataSource clearGraphObjects];
    [self.selectionManager clearSelectionInTableView:self.tableView];
    [self.tableView reloadData];
    [self.loader reset];
}

#pragma mark - public class members

+ (FBCacheDescriptor*)cacheDescriptor {
    return [[[FBFriendPickerCacheDescriptor alloc] init] autorelease];
}

+ (FBCacheDescriptor*)cacheDescriptorWithUserID:(NSString*)userID
                               fieldsForRequest:(NSSet*)fieldsForRequest {
    return [[[FBFriendPickerCacheDescriptor alloc] initWithUserID:userID
                                                 fieldsForRequest:fieldsForRequest]
            autorelease];
}


#pragma mark - private members

- (FBRequest*)requestForLoadData {
    
    // Respect user settings in case they have changed.
    NSMutableArray *sortFields = [NSMutableArray array];
    NSString *groupByField = nil;
    if (self.sortOrdering == FBFriendSortByFirstName) {
        [sortFields addObject:@"first_name"];
        [sortFields addObject:@"middle_name"];
        [sortFields addObject:@"last_name"];
        groupByField = @"first_name";
    } else {
        [sortFields addObject:@"last_name"];
        [sortFields addObject:@"first_name"];
        [sortFields addObject:@"middle_name"];
        groupByField = @"last_name";
    }
    [self.dataSource setSortingByFields:sortFields ascending:YES];
    self.dataSource.groupByField = groupByField;
    self.dataSource.useCollation = YES;
    
    // me or one of my friends that also uses the app
    NSString *user = self.userID;
    if (!user) {
        user = @"me";
    }
    
    // create the request and start the loader
    FBRequest *request = [FBFriendPickerViewController requestWithUserID:user
                                                                  fields:self.fieldsForRequest
                                                              dataSource:self.dataSource
                                                                 session:self.session];
    return request;
}

- (void)loadDataSkippingRoundTripIfCached:(NSNumber*)skipRoundTripIfCached {
    if (self.session) {
        [self.loader startLoadingWithRequest:[self requestForLoadData]
                               cacheIdentity:FBFriendPickerCacheIdentity
                       skipRoundtripIfCached:skipRoundTripIfCached.boolValue];
    }
}

+ (FBRequest*)requestWithUserID:(NSString*)userID
                         fields:(NSSet*)fields
                     dataSource:(FBGraphObjectTableDataSource*)datasource
                        session:(FBSession*)session {
    
    FBRequest *request = [FBRequest requestForGraphPath:[NSString stringWithFormat:@"%@/friends", userID]];
    [request setSession:session];
    
    NSString *allFields = [datasource fieldsForRequestIncluding:fields,
                           @"id", 
                           @"name", 
                           @"first_name", 
                           @"middle_name",
                           @"last_name", 
                           @"picture", 
                           nil];
    [request.parameters setObject:allFields forKey:@"fields"];
    
    return request;
}

- (void)centerAndStartSpinner {
    [FBUtility centerView:self.spinner tableView:self.tableView];
    [self.spinner startAnimating];    
}

#pragma mark - FBGraphObjectSelectionChangedDelegate

- (void)graphObjectTableSelectionDidChange:(FBGraphObjectTableSelection *)selection {
    if ([self.delegate respondsToSelector:
         @selector(friendPickerViewControllerSelectionDidChange:)]) {
        [(id)self.delegate friendPickerViewControllerSelectionDidChange:self];
    }
}

#pragma mark - FBGraphObjectViewControllerDelegate

- (BOOL)graphObjectTableDataSource:(FBGraphObjectTableDataSource *)dataSource
                filterIncludesItem:(id<FBGraphObject>)item {
    id<FBGraphUser> user = (id<FBGraphUser>)item;
    
    BOOL shouldShow = YES;
    
    if ([self.delegate
         respondsToSelector:@selector(friendPickerViewController:shouldIncludeUser:)]) {
        shouldShow = [(id)self.delegate friendPickerViewController:self
                                                 shouldIncludeUser:user];
    }
    
    NSString *searchText = [[self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (searchText.length > 0) {
        shouldShow = ([[[user name] lowercaseString] rangeOfString:searchText].location != NSNotFound);
    }
    
    return shouldShow;
}

- (NSString *)graphObjectTableDataSource:(FBGraphObjectTableDataSource *)dataSource
                             titleOfItem:(id<FBGraphUser>)graphUser {
    // Title is either "First Middle" or "Last" depending on display order.
    if (self.displayOrdering == FBFriendDisplayByFirstName) {
        if (graphUser.middle_name) {
            return [NSString stringWithFormat:@"%@ %@", graphUser.first_name, graphUser.middle_name];
        } else {
            return graphUser.first_name;
        }
    } else {
        return graphUser.last_name;
    }
}

- (NSString *)graphObjectTableDataSource:(FBGraphObjectTableDataSource *)dataSource
                       titleSuffixOfItem:(id<FBGraphUser>)graphUser {
    // Title suffix is either "Last" or "First Middle" depending on display order.
    if (self.displayOrdering == FBFriendDisplayByLastName) {
        if (graphUser.middle_name) {
            return [NSString stringWithFormat:@"%@ %@", graphUser.first_name, graphUser.middle_name];
        } else {
            return graphUser.first_name;
        }
    } else {
        return graphUser.last_name;
    }
    
}

- (NSString *)graphObjectTableDataSource:(FBGraphObjectTableDataSource *)dataSource
                       pictureUrlOfItem:(id<FBGraphObject>)graphObject {
    id picture = [graphObject objectForKey:@"picture"];
    // Depending on what migration the app is in, we may get back either a string, or a
    // dictionary with a "data" property that is a dictionary containing a "url" property.
    if ([picture isKindOfClass:[NSString class]]) {
        return picture;
    }
    id data = [picture objectForKey:@"data"];
    return [data objectForKey:@"url"];
}

- (void)graphObjectTableDataSource:(FBGraphObjectTableDataSource*)dataSource
                customizeTableCell:(FBGraphObjectTableCell*)cell {
    // We want to bold whichever part of the name we are sorting on.
    cell.boldTitle = (self.sortOrdering == FBFriendSortByFirstName && self.displayOrdering == FBFriendDisplayByFirstName) ||
        (self.sortOrdering == FBFriendSortByLastName && self.displayOrdering == FBFriendDisplayByLastName);
    cell.boldTitleSuffix = (self.sortOrdering == FBFriendSortByFirstName && self.displayOrdering == FBFriendDisplayByLastName) ||
        (self.sortOrdering == FBFriendSortByLastName && self.displayOrdering == FBFriendDisplayByFirstName);    
}

#pragma mark FBGraphObjectPagingLoaderDelegate members

- (void)pagingLoader:(FBGraphObjectPagingLoader*)pagingLoader willLoadURL:(NSString*)url {
    [self centerAndStartSpinner];
}

- (void)pagingLoader:(FBGraphObjectPagingLoader*)pagingLoader didLoadData:(NSDictionary*)results {
    // This logging currently goes here because we're effectively complete with our initial view when 
    // the first page of results come back.  In the future, when we do caching, we will need to move
    // this to a more appropriate place (e.g., after the cache has been brought in).
    [FBLogger singleShotLogEntry:FBLoggingBehaviorPerformanceCharacteristics
                    timestampTag:self
                    formatString:@"Friend Picker: first render "];  // logger will append "%d msec"
    
    
    if ([self.delegate respondsToSelector:@selector(friendPickerViewControllerDataDidChange:)]) {
        [(id)self.delegate friendPickerViewControllerDataDidChange:self];
    }
}

- (void)pagingLoaderDidFinishLoading:(FBGraphObjectPagingLoader *)pagingLoader {
    // finished loading, stop animating
    [self.spinner stopAnimating];
    
    // Call the delegate from here as well, since this might be the first response of a query
    // that has no results.
    if ([self.delegate respondsToSelector:@selector(friendPickerViewControllerDataDidChange:)]) {
        [(id)self.delegate friendPickerViewControllerDataDidChange:self];
    }

    // if our current display is from cache, then kick-off a near-term refresh
    if (pagingLoader.isResultFromCache) {
        [self performSelector:@selector(loadDataSkippingRoundTripIfCached:) 
                   withObject:[NSNumber numberWithBool:NO]
                   afterDelay:FBRefreshCacheDelaySeconds];
    }    
}

- (void)pagingLoader:(FBGraphObjectPagingLoader*)pagingLoader handleError:(NSError*)error {
    if ([self.delegate
         respondsToSelector:@selector(friendPickerViewController:handleError:)]) {
        [(id)self.delegate friendPickerViewController:self handleError:error];
    }
}

- (void)pagingLoaderWasCancelled:(FBGraphObjectPagingLoader*)pagingLoader {
    [self.spinner stopAnimating];
}

#pragma mark UISearchBarDelegate methods

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self updateView];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = nil;
    [searchBar resignFirstResponder];
    [self updateView];
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification*)note {
    NSDictionary *userInfo = note.userInfo;
    CGRect frameEnd = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] intValue];
    UIViewAnimationOptions options = 0;
    switch (curve) {
        case UIViewAnimationCurveEaseIn:
            options |= UIViewAnimationOptionCurveEaseIn;
            break;
        case UIViewAnimationCurveEaseOut:
            options |= UIViewAnimationOptionCurveEaseOut;
            break;
        case UIViewAnimationCurveEaseInOut:
            options |= UIViewAnimationOptionCurveEaseInOut;
            break;
        case UIViewAnimationCurveLinear:
            options |= UIViewAnimationOptionCurveLinear;
            break;
    }
    
    CGRect frameInView = [self.tableView.superview convertRect:frameEnd fromView:nil];
    CGRect tableViewFrame = self.tableView.superview.bounds;
    tableViewFrame.origin.y = CGRectGetMaxY(_searchBar.frame);
    tableViewFrame.size.height = frameInView.origin.y - tableViewFrame.origin.y;
    
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:options
                     animations:^{
                         _tableView.frame = tableViewFrame;
                     }
                     completion:^(BOOL finished) {
                     }];
}

- (void)keyboardWillHide:(NSNotification*)note {
    NSDictionary *userInfo = note.userInfo;
    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] intValue];
    UIViewAnimationOptions options = 0;
    switch (curve) {
        case UIViewAnimationCurveEaseIn:
            options |= UIViewAnimationOptionCurveEaseIn;
            break;
        case UIViewAnimationCurveEaseOut:
            options |= UIViewAnimationOptionCurveEaseOut;
            break;
        case UIViewAnimationCurveEaseInOut:
            options |= UIViewAnimationOptionCurveEaseInOut;
            break;
        case UIViewAnimationCurveLinear:
            options |= UIViewAnimationOptionCurveLinear;
            break;
    }
    
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:options
                     animations:^{
                         CGRect tableViewFrame = self.tableView.superview.bounds;
                         tableViewFrame.origin.y = CGRectGetMaxY(_searchBar.frame);
                         tableViewFrame.size.height -= tableViewFrame.origin.y;
                         _tableView.frame = tableViewFrame;
                     }
                     completion:^(BOOL finished) {
                     }];
}

@end
