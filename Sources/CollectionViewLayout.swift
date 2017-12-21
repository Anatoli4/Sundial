//
//  CollectionViewLayout.swift
//  PSGOneApp
//
//  Created by Eugen Filipkov on 4/17/17.
//  Copyright © 2017 Netcosports. All rights reserved.
//

import UIKit
import Astrolabe
import RxSwift
import RxCocoa

open class CollectionViewLayout<T: CollectionViewSource,
  TitleCell: CollectionViewCell,
  MarkerCell: CollectionViewCell>: UICollectionViewFlowLayout
where T: Selectable, TitleCell: Reusable, TitleCell.Data: ViewModelable {

  public typealias ViewModel = TitleCell.Data

  open override func prepare() {
    super.prepare()
    register(DecorationView<TitleCell, MarkerCell>.self, forDecorationViewOfKind: DecorationViewId)
  }

  public typealias PagerClosure = ()->[ViewModel]

  open weak var hostPagerSource: T?
  open var pager: PagerClosure?
  open var pageStripBackgroundColor = UIColor.clear
  open var settings: Settings = Settings()

  let disposeBag = DisposeBag()
  private var jumpSourceLayoutAttribute: UICollectionViewLayoutAttributes?
  private var jumpTargetLayoutAttribute: UICollectionViewLayoutAttributes?

  public init(hostPagerSource: T, settings: Settings? = nil, pager: PagerClosure?) {
    super.init()

    sectionInset = .zero
    minimumLineSpacing = 0.0
    minimumInteritemSpacing = 0.0
    scrollDirection = .horizontal

    self.hostPagerSource = hostPagerSource
    self.pager = pager
    if let settings = settings {
      self.settings = settings
    }

    switch self.settings.alignment {
    case .topOffset(let variable):
      variable.asDriver().drive(onNext: { [weak self] _ in
        self?.invalidateLayout()
      }).disposed(by: disposeBag)
    default: break
    }
  }

  required public init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  open override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    let oldAttributes = super.layoutAttributesForElements(in: rect)
    guard var attributes = oldAttributes?.flatMap({ $0.copy() as? UICollectionViewLayoutAttributes }) else {
      return oldAttributes
    }

    addDecorationAttributes(to: &attributes)
    addJumpAttributes(to: &attributes)
    return attributes
  }

  open override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    return layoutAttributesForElements(in: .infinite)?
      .filter { $0.representedElementCategory == .cell }
      .first(where: { $0.indexPath == indexPath })
  }

  open var decorationFrame: CGRect {
    guard let collectionView = collectionView else { return .zero }
    let topOffset: CGFloat
    switch settings.alignment {
    case .top:
      topOffset = 0.0
    case .topOffset(let variable):
      topOffset = variable.value
    }

    return CGRect(x: collectionView.contentOffset.x,
                  y: topOffset,
                  width: collectionView.frame.width,
                  height: settings.stripHeight)
  }

  open func adjustItem(frame: CGRect) -> CGRect {
    let bottom = settings.bottomStripSpacing
    let height = settings.stripHeight

    return CGRect(x: frame.origin.x,
                  y: height + bottom,
                  width: frame.width,
                  height: frame.height - height - bottom)
  }

  open override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    return true
  }
}

// MARK: - Private

private extension CollectionViewLayout {

  func addDecorationAttributes(to attributes: inout [UICollectionViewLayoutAttributes]) {
    guard attributes.count > 0 else { return }
    guard let decorationAttributes = self.decorationAttributes(with: pager?()) else {
      return
    }

    attributes.forEach {
      $0.frame = adjustItem(frame: $0.frame)
    }
    attributes.append(decorationAttributes)
  }

  func decorationAttributes(with titles: [ViewModel]?) -> UICollectionViewLayoutAttributes? {
    guard let titles = titles, titles.count > 0 else {
      return nil
    }

    let decorationIndexPath = IndexPath(item: 0, section: 0)
    let decorationAttributes = DecorationViewAttributes<ViewModel>(forDecorationViewOfKind: DecorationViewId, with: decorationIndexPath)
    decorationAttributes.zIndex = 1024
    decorationAttributes.settings = settings
    decorationAttributes.titles = titles
    decorationAttributes.hostPagerSource = hostPagerSource
    decorationAttributes.backgroundColor = pageStripBackgroundColor
    decorationAttributes.selectionClosure = { [weak self] in
      guard let `self` = self else { return }

      self.select(item: $0, jumpingPolicy: self.settings.jumpingPolicy)
    }
    decorationAttributes.frame = decorationFrame
    return decorationAttributes
  }
}

// MARK: - Jumping

private extension CollectionViewLayout {

  func select(item: Int, jumpingPolicy: JumpingPolicy) {
    let threashold: Int
    switch jumpingPolicy {
    case .disabled: threashold = .max
    case .skip(let pages): threashold = max(pages, 2)
    }
    guard let currentIndex = self.currentIndex(),
      abs(currentIndex - item) >= threashold else {
        hostPagerSource?.selectedItem.onNext(item)
        return
    }
    jump(from: currentIndex, to: item)
  }

  func currentIndex() -> Int? {
    guard let source = hostPagerSource,
      let containerView = source.containerView,
      containerView.bounds.size.width > 0.0 else {
        return nil
    }

    let index = Int(containerView.contentOffset.x / containerView.bounds.size.width)
    let pagesCount = source.sections.first?.cells.count ?? 0
    let result = max(0, min(index, pagesCount - 1))
    return result
  }

  func jump(from source: Int, to target: Int) {
    if jumpTargetLayoutAttribute != nil || jumpSourceLayoutAttribute != nil {
      return
    }

    let sourceIndex = IndexPath(item: source, section: 0)
    let targetIndex = IndexPath(item: target, section: 0)
    guard let sourceLayoutAttributes = layoutAttributesForItem(at: sourceIndex)?.copy() as? UICollectionViewLayoutAttributes,
      let targetLayoutAttributes = layoutAttributesForItem(at: targetIndex)?.copy() as? UICollectionViewLayoutAttributes else {
        return
    }

    jumpTargetLayoutAttribute = targetLayoutAttributes
    jumpSourceLayoutAttribute = sourceLayoutAttributes

    invalidateLayout()
    hostPagerSource?.containerView?.isUserInteractionEnabled = false
    hostPagerSource?.containerView?.layoutIfNeeded()
    hostPagerSource?.selectedItem.onNext(target)
  }

  func addJumpAttributes(to attributes: inout [UICollectionViewLayoutAttributes]) {
    guard attributes.count > 0 else { return }
    guard let containerView = hostPagerSource?.containerView else { return }
    guard let source = jumpSourceLayoutAttribute?.copy() as? UICollectionViewLayoutAttributes,
      let target = jumpTargetLayoutAttribute?.copy() as? UICollectionViewLayoutAttributes else {
        return
    }

    let sourceStartFrame = source.frame
    let targetEndFrame = target.frame
    let width = containerView.frame.size.width
    let offet = containerView.contentOffset.x
    let midPoint = offet + width * 0.5
    let distanceLeft = abs(targetEndFrame.midX - midPoint)
    let totalDistance = abs(targetEndFrame.midX - sourceStartFrame.midX)
    guard totalDistance > 0.0, distanceLeft > 0.0, target.indexPath.item != source.indexPath.item else {
      finalizeJumpTransition()
      return
    }

    let pagesDistance = CGFloat(abs(target.indexPath.item - source.indexPath.item))
    let progressPerPage = 1.0 / pagesDistance
    let progress = 1.0 - (distanceLeft / totalDistance)

    let sourceEndProgress = 1.0 - progressPerPage
    let sourceEndFrame = sourceStartFrame
      .linearInterpolation(with: targetEndFrame, value: sourceEndProgress)
    let sourceFrame = sourceStartFrame
      .linearInterpolation(with: sourceEndFrame, value: progress)
    source.frame = sourceFrame

    let targetStartProgress = progressPerPage
    let targetStartFrame = sourceStartFrame
      .linearInterpolation(with: targetEndFrame, value: targetStartProgress)
    let targetFrame = targetStartFrame
      .linearInterpolation(with: targetEndFrame, value: progress)
    target.frame = targetFrame

    attributes = attributes.filter { $0.representedElementCategory != .cell }
    attributes.append(contentsOf: [source, target])
  }

  func finalizeJumpTransition() {
    jumpTargetLayoutAttribute = nil
    jumpSourceLayoutAttribute = nil
    hostPagerSource?.containerView?.isUserInteractionEnabled = true
  }
}
