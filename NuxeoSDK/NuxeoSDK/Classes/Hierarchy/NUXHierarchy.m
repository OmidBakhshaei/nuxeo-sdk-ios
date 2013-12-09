//
// Created by Arnaud Kervern on 26/11/13.
// Copyright (c) 2013 Nuxeo. All rights reserved.
//

#import "NUXHierarchy.h"
#import "NUXHierarchyDB.h"

#define kRootKey @"0"

@interface NUXHierarchy (private)

-(void)setName:(NSString *)name;

@end

@implementation NUXHierarchy {
    bool _isLoaded;
    bool _isFailure;
    NSString *_name;
}

+(NUXHierarchy *)hierarchyWithName:(NSString *)name {
    static dispatch_once_t pred = 0;
    static NSMutableDictionary *__strong _hierarchies = nil;
    
    dispatch_once(&pred, ^{
        _hierarchies = [NSMutableDictionary new];
    });
    
    if (![_hierarchies objectForKey:name]) {
        NUXHierarchy *hierarchy = [NUXHierarchy new];
        [hierarchy setName:name];
        
        [_hierarchies setObject:hierarchy forKey:name];
    }
    
    return [_hierarchies objectForKey:name];
}

-(id)init {
    self = [super init];
    if (self) {
        _isLoaded = NO;
        _isFailure = NO;
    }
    return self;
}

- (void)dealloc
{
    _completionBlock= nil;
    _nodeInvalidationBlock = nil;
    _nodeBlock = nil;
}

-(void)setName:(NSString *)name {
    _name = name;
}

-(void)loadWithRequest:(NUXRequest *)request {
    _request = request;
    if ([[self childrenOfRoot] count] <= 0) {
        [self setup];
    }
}

-(void)resetCache {
    [[NUXHierarchyDB shared] deleteNodesFromHierarchy:_name];
}

-(NSArray *)childrenOfDocument:(NUXDocument *)document
{
    NSArray *entries = [[NUXHierarchyDB shared] selectNodesFromParent:document.uid hierarchy:_name];
    if (entries == nil) {
        return nil;
    }
    return [NSArray arrayWithArray:entries];
}

-(NSArray *)contentOfDocument:(NUXDocument *)document {
    return [[NUXHierarchyDB shared] selectContentFromNode:document.uid hierarchy:_name];
}

-(NSArray *)contentOfAllDocuments {
    return [[NUXHierarchyDB shared] selectAllContentFromHierarchy:_name];
}

-(NSArray *)childrenOfRoot
{
    NSArray *entries = [[NUXHierarchyDB shared] selectNodesFromParent:kRootKey hierarchy:_name];
    if (entries == nil) {
        [NSException raise:@"Not initialized" format:@"Hierarchy not initialized"];
    }
    return [NSArray arrayWithArray:entries];
}

-(bool)isLoaded
{
    return _isLoaded;
}

-(void)waitUntilLoadingIsDone {
    while (!(_isLoaded || _isFailure) && [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
}


-(void)setupCompleted
{
    _isLoaded = YES;
    if (self.completionBlock != nil) {
        self.completionBlock();
    }
}

-(void)setup
{
    NSMutableArray *docs = [NSMutableArray new];
    
    // Block passed to request filled with all expected documents
    void (^appendDocs)(NUXRequest *) = ^(NUXRequest *request) {
        NUXDocuments *res = [request responseEntityWithError:nil];
        [docs addObjectsFromArray:res.entries];
        if (res.isNextPageAvailable) {
            [request addParameterValue:[NSString stringWithFormat:@"%@", @(res.currentPageIndex + 1)] forKey:@"currentPageIndex"];
            [request start];
        } else {
            [self startBuildingHierarchyWithDocuments:docs];
        }
    };
    
    void (^failureBlock)(NUXRequest *) = ^(NUXRequest *request) {
        _isFailure = YES;
    };
    
    [self.request setCompletionBlock:appendDocs];
    [self.request setFailureBlock:failureBlock];
    [self.request start];
}

-(void)startBuildingHierarchyWithDocuments:(NSArray *)documents
{
    documents = [documents sortedArrayUsingComparator:^NSComparisonResult(NUXDocument *doc1, NUXDocument *doc2) {
        return [doc1.path compare:doc2.path];
    }];
    
    NSMutableDictionary *hierarchicalDocs = [NSMutableDictionary new];
    [documents enumerateObjectsUsingBlock:^(NUXDocument *doc, NSUInteger idx, BOOL *stop) {
        NSString *parent = [doc.path stringByDeletingLastPathComponent];
        NSMutableArray *children = [hierarchicalDocs objectForKey:parent];
        if (children == nil) {
            children = [NSMutableArray new];
            [hierarchicalDocs setObject:children forKey:parent];
        }
        [children addObject:doc];
    }];
    
    [self buildHierarchy:documents];
    [self setupCompleted];
}

-(void)buildHierarchy:(NSArray *)pDocuments {
    if (pDocuments.count == 0) {
        [NSException raise:@"Empty array" format:@"Hierarchy initialized with an empty array."];
    }
    
    NSMutableArray *documents = [NSMutableArray arrayWithArray:pDocuments];
    NSMutableArray *__block parents = [NSMutableArray new];
    [documents enumerateObjectsUsingBlock:^(NUXDocument *doc, NSUInteger idx, BOOL *stop) {
        // Try to find if a passed parent exists.
        NUXDocument *parent;
        NUXDebug(@"doc: %@", doc);
        do {
            if (parent != nil) {
                // If we have to test the previous parent; we are in a leaf node
                [parents removeLastObject];
            }
            
            parent = [parents lastObject];
            NUXDebug(@"  parent: %@", parent);
        } while (!(parent == nil || [doc.path hasPrefix:[NSString stringWithFormat:@"%@/", parent.path]]));

        NSString *hKey = parent == nil ? kRootKey : parent.uid;
        [[NUXHierarchyDB shared] insertNodes:@[doc] fromHierarchy:_name withParent:hKey];
        //[NUXHierarchy addNodeDocument:doc toHierarchy:_documents key:hKey];
        
        if (_nodeBlock) {
            NSArray *leaf = _nodeBlock(doc, parents.count);
            if ([leaf count] > 0) {
                [[NUXHierarchyDB shared] insertcontent:leaf fromHierarchy:_name forNode:doc.uid];
            }
        }
        
        [parents addObject:doc];
    }];
}

+(void)addNodeDocument:(NUXDocument *)child toHierarchy:(NSDictionary *)hierarchy key:(NSString *)key {
    [NUXHierarchy addNodeDocuments:@[child] toHierarchy:hierarchy key:key];
}

+(void)addNodeDocuments:(NSArray *)children toHierarchy:(NSDictionary *)hierarchy key:(NSString *)key  {
    if (!([children count] > 0)) {
        return;
    }
    
    NSMutableArray *hChildren = [hierarchy objectForKey:key];
    if (!hChildren) {
        hChildren = [NSMutableArray new];
        [hierarchy setValue:hChildren forKey:key];
    }
    [hChildren addObjectsFromArray:children];
}

@end