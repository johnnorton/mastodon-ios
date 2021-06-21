//
//  AsyncHomeTimelineViewModel+Diffable.swift
//  Mastodon
//
//  Created by MainasuK Cirno on 2021-6-21.
//

import os.log
import UIKit
import CoreData
import CoreDataStack
import AsyncDisplayKit
import DifferenceKit
import DiffableDataSources

extension AsyncHomeTimelineViewModel {

    func setupDiffableDataSource(
        tableNode: ASTableNode,
        dependency: NeedsDependency,
        statusTableViewCellDelegate: StatusTableViewCellDelegate,
        timelineMiddleLoaderTableViewCellDelegate: TimelineMiddleLoaderTableViewCellDelegate
    ) {
        tableNode.automaticallyAdjustsContentOffset = true

        diffableDataSource = StatusSection.tableNodeDiffableDataSource(
            tableNode: tableNode,
            managedObjectContext: fetchedResultsController.managedObjectContext
        )

        var snapshot = DiffableDataSourceSnapshot<StatusSection, Item>()
        snapshot.appendSections([.main])
        diffableDataSource?.apply(snapshot)
    }

}

// MARK: - NSFetchedResultsControllerDelegate
extension AsyncHomeTimelineViewModel: NSFetchedResultsControllerDelegate {
    
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        os_log("%{public}s[%{public}ld], %{public}s", ((#file as NSString).lastPathComponent), #line, #function)
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeContentWith snapshot: NSDiffableDataSourceSnapshotReference) {
        os_log("%{public}s[%{public}ld], %{public}s", ((#file as NSString).lastPathComponent), #line, #function)

        guard let diffableDataSource = self.diffableDataSource else { return }
        let oldSnapshot = diffableDataSource.snapshot()

        let predicate = fetchedResultsController.fetchRequest.predicate
        let parentManagedObjectContext = fetchedResultsController.managedObjectContext
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        managedObjectContext.parent = parentManagedObjectContext

        managedObjectContext.perform {
            var shouldAddBottomLoader = false

            let timelineIndexes: [HomeTimelineIndex] = {
                let request = HomeTimelineIndex.sortedFetchRequest
                request.returnsObjectsAsFaults = false
                request.predicate = predicate
                do {
                    return try managedObjectContext.fetch(request)
                } catch {
                    assertionFailure(error.localizedDescription)
                    return []
                }
            }()

            // that's will be the most fastest fetch because of upstream just update and no modify needs consider

            var oldSnapshotAttributeDict: [NSManagedObjectID : Item.StatusAttribute] = [:]

            for item in oldSnapshot.itemIdentifiers {
                guard case let .homeTimelineIndex(objectID, attribute) = item else { continue }
                oldSnapshotAttributeDict[objectID] = attribute
            }

            var newTimelineItems: [Item] = []

            for (i, timelineIndex) in timelineIndexes.enumerated() {
                let attribute = oldSnapshotAttributeDict[timelineIndex.objectID] ?? Item.StatusAttribute()
                attribute.isSeparatorLineHidden = false

                // append new item into snapshot
                newTimelineItems.append(.homeTimelineIndex(objectID: timelineIndex.objectID, attribute: attribute))

                let isLast = i == timelineIndexes.count - 1
                switch (isLast, timelineIndex.hasMore) {
                case (false, true):
                    newTimelineItems.append(.homeMiddleLoader(upperTimelineIndexAnchorObjectID: timelineIndex.objectID))
                    attribute.isSeparatorLineHidden = true
                case (true, true):
                    shouldAddBottomLoader = true
                default:
                    break
                }
            }   // end for

            var newSnapshot = DiffableDataSourceSnapshot<StatusSection, Item>()
            newSnapshot.appendSections([.main])
            newSnapshot.appendItems(newTimelineItems, toSection: .main)

            let endSnapshot = CACurrentMediaTime()

            if shouldAddBottomLoader, !(self.loadoldestStateMachine.currentState is LoadOldestState.NoMore) {
                newSnapshot.appendItems([.bottomLoader], toSection: .main)
            }

            diffableDataSource.apply(newSnapshot, animatingDifferences: false) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.isFetchingLatestTimeline.value = false
                }

                let end = CACurrentMediaTime()
                os_log("%{public}s[%{public}ld], %{public}s: calculate home timeline layout cost %.2fs", ((#file as NSString).lastPathComponent), #line, #function, end - endSnapshot)
            }
        }   // end perform
    }
    
    private struct Difference<T> {
        let item: T
        let sourceIndexPath: IndexPath
        let targetIndexPath: IndexPath
        let offset: CGFloat
    }
    
    private func calculateReloadSnapshotDifference<T: Hashable>(
        navigationBar: UINavigationBar,
        tableView: UITableView,
        oldSnapshot: DiffableDataSourceSnapshot<StatusSection, T>,
        newSnapshot: DiffableDataSourceSnapshot<StatusSection, T>
    ) -> Difference<T>? {
        guard oldSnapshot.numberOfItems != 0 else { return nil }
        
        // old snapshot not empty. set source index path to first item if not match
        let sourceIndexPath = UIViewController.topVisibleTableViewCellIndexPath(in: tableView, navigationBar: navigationBar) ?? IndexPath(row: 0, section: 0)
        
        guard sourceIndexPath.row < oldSnapshot.itemIdentifiers(inSection: .main).count else { return nil }
        
        let timelineItem = oldSnapshot.itemIdentifiers(inSection: .main)[sourceIndexPath.row]
        guard let itemIndex = newSnapshot.itemIdentifiers(inSection: .main).firstIndex(of: timelineItem) else { return nil }
        let targetIndexPath = IndexPath(row: itemIndex, section: 0)
        
        let offset = UIViewController.tableViewCellOriginOffsetToWindowTop(in: tableView, at: sourceIndexPath, navigationBar: navigationBar)
        return Difference(
            item: timelineItem,
            sourceIndexPath: sourceIndexPath,
            targetIndexPath: targetIndexPath,
            offset: offset
        )
    }
    
}