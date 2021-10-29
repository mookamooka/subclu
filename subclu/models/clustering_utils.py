"""
Utils for clustering.

sklearn doesn't have tools out of the box to introspect hierarchical clusters
and scipy's tools need a little tweaking (like these fxns).

reference:
- Describe different ways to use scipy's tools
    - https://joernhees.de/blog/2015/08/26/scipy-hierarchical-clustering-and-dendrogram-tutorial/
"""
import logging
from pathlib import Path
from typing import Union, Tuple

from matplotlib import pyplot as plt
from matplotlib import cm
import numpy as np
import pandas as pd

from scipy.cluster.hierarchy import dendrogram


def create_linkage_for_dendrogram(model) -> pd.DataFrame:
    """
    Create linkage matrix from an Sklearn model (e.g., AgglomerativeCluster)
    We can use this matrix to plot a dendogram and create cluster labels using fcluster.
    """
    # create the counts of samples under each node
    counts = np.zeros(model.children_.shape[0])
    n_samples = len(model.labels_)
    for i, merge in enumerate(model.children_):
        current_count = 0
        for child_idx in merge:
            if child_idx < n_samples:
                current_count += 1  # leaf node
            else:
                current_count += counts[child_idx - n_samples]
        counts[i] = current_count

    linkage_matrix = pd.DataFrame(
        np.column_stack(
            [model.children_,
             model.distances_,
             counts]
        ),
        columns=['children_0', 'children_1', 'distance', 'count'],
    ).astype({
        'children_0': int,
        'children_1': int,
        'distance': float,
        'count': int,
    })

    return linkage_matrix


def fancy_dendrogram(
        Z: Union[pd.DataFrame, np.ndarray],
        max_d: float = None,
        annotate_above: float = 0,
        plot_title: str = 'Hierarchical Clustering Dendrogram (truncated)',
        xlabel: str = 'item index OR (cluster size)',
        ylabel: str = 'distance',
        dist_fontsize: float = 13,
        save_path: Union[str, Path] = None,
        **kwargs
):
    """Wrapper around dendogram diagram that adds distances & cut off
    TODO(djb): fix orientation right or left:
        - The axis labels are flipped
        - The distances are in the wront place
    """
    if max_d and 'color_threshold' not in kwargs:
        kwargs['color_threshold'] = max_d

    fig = plt.figure(figsize=(14, 8))
    ddata = dendrogram(Z, **kwargs)

    if not kwargs.get('no_plot', False):
        plt.title(plot_title)
        plt.xlabel(xlabel)
        plt.ylabel(ylabel)
        for i, d, c in zip(ddata['icoord'], ddata['dcoord'], ddata['color_list']):
            x = 0.5 * sum(i[1:3])
            y = d[1]
            if y > annotate_above:
                plt.plot(x, y, 'o', c=c)
                # original format: "%.3g"
                plt.annotate(f"{y:.1f}", (x, y), xytext=(0, -5),
                             textcoords='offset points',
                             fontsize=dist_fontsize,
                             va='top', ha='center')
        if max_d:
            plt.axhline(y=max_d, c='k')

    if save_path is not None:
        plt.savefig(
            save_path,
            dpi=200, bbox_inches='tight', pad_inches=0.2
        )
    return ddata


def plot_elbow_and_get_k(
        Z: Union[pd.DataFrame, np.ndarray],
        n_clusters_to_check: int = 500,
        figsize: tuple = (14, 8),
        plot_title: str = 'Cluster Distances & Optimal k',
        xlabel: str = 'Number of clusters (k)',
        ylabel: str = 'Distance',
        col_optimal_k: str = 'optimal_k_for_interval',
        save_path: Union[str, Path] = None,
        return_optimal_ks: bool = False,
) -> Union[pd.DataFrame, Tuple[pd.DataFrame, dict]]:
    """Use 'elbow' method to get an optimal value of k-clusters"""
    fig = plt.figure(figsize=figsize)

    try:
        last = Z[-n_clusters_to_check:, 2]
    except TypeError:
        last = Z.to_numpy()[-n_clusters_to_check:, 2]

    last_rev = last[::-1]
    idxs = np.arange(1, len(last) + 1)
    plt.plot(idxs, last_rev, label='distances')

    acceleration = np.diff(last, 2)  # 2nd derivative of the distances
    acceleration_rev = acceleration[::-1]

    # create a df to track k, acceleration, and best-k in n interval
    df_accel = (
        pd.DataFrame(
            {'acceleration': acceleration_rev}
        )
        .reset_index()
        .assign(index=lambda x: x['index'] + 2)
        .rename(columns={'index': 'k'})
    )

    k_intervals = [
        # (2, 10),  # This one is so generic it's kind of useless
        (10, 20),
        (20, 50),
        (50, 100),
        (100, 200),
        (200, 300),
        (300, 400),
        (400, 600),
    ]
    viridis = cm.get_cmap('viridis', len(k_intervals))

    d_optimal_k = dict()
    for i, k_tup_ in enumerate(k_intervals):
        mask_interval_coT = df_accel['k'].between(*k_tup_)
        interval_name = f"{k_tup_[0]:03d}_to_{k_tup_[1]:03d}"
        d_optimal_k[interval_name] = dict()
        try:
            df_accel.loc[
                (df_accel.index == df_accel[mask_interval_coT]['acceleration'].idxmax()),
                col_optimal_k
            ] = interval_name

            k_ = df_accel.loc[
                (df_accel.index == df_accel[mask_interval_coT]['acceleration'].idxmax()),
                'k'
            ].values[0]
            d_optimal_k[interval_name]['k'] = int(k_)  # convert to int b/c np.int can create errors
            d_optimal_k[interval_name]['col_prefix'] = f"{k_:03d}_k"

            plt.axvline(x=k_, linestyle="--", label=f"k={k_}", color=viridis(i / len(k_intervals)))
        except Exception as e:
            logging.warning(f"{e}")

    plt.title(plot_title)
    plt.xlabel(xlabel)
    plt.ylabel(ylabel)

    plt.plot(idxs[:-2] + 1, acceleration_rev, label='acceleration')
    plt.legend(loc=(1.02, 0.42))

    if save_path is not None:
        plt.savefig(
            save_path,
            dpi=200, bbox_inches='tight', pad_inches=0.2
        )
    # NOTE: if you plt.show() before saving, plt will create a new fig and won't be able to
    #  save the figure

    if return_optimal_ks:
        return df_accel, d_optimal_k
    else:
        return df_accel


# def calculate_metrics_with_ground_truth(
# ):
#     """"""
#     d_df_crosstab_labels = dict()
#     d_metrics = dict()
#     val_fill_pred_nulls = 'Meta/Reddit'
#
#     l_cols_ground_truth = [
#         # 'rating_name',
#         'primary_topic',
#     ]
#
#     df_labels_coF_meta = df_labels_coF.merge(
#         df_subs[l_ix_sub + l_cols_ground_truth],
#         how='left',
#         on=l_ix_sub,
#     ).copy()
#
#     l_cols_predicted = list()
#
#     # for interval_ in tqdm(intervals_to_test):
#     for interval_ in df_accel_coF[col_optimal_k].dropna().unique():
#         print(f"=== Interval: {interval_} ===")
#         col_cls_labels = f"{interval_}_labels"
#         d_df_crosstab_labels[col_cls_labels] = dict()
#         d_metrics[col_cls_labels] = dict()
#
#         for c_tl in l_cols_ground_truth:
#             # For some reason the nulls in this table are the string 'null'! ugh
#             mask_not_null_gt = ~(
#                     (df_labels_coF_meta[c_tl].isnull()) |
#                     (df_labels_coF_meta[c_tl] == 'null')
#             )
#             # print(f"  Nulls: {(~mask_not_null_gt).sum():,.0f}")
#             d_df_crosstab_labels[col_cls_labels][c_tl] = pd.crosstab(
#                 df_labels_coF_meta[mask_not_null_gt][col_cls_labels],
#                 df_labels_coF_meta[mask_not_null_gt][c_tl]
#             )
#
#             # Create new predicted column
#             col_pred_ = f"{interval_}-predicted-{c_tl}"
#             l_cols_predicted.append(col_pred_)
#             df_labels_coF_meta = df_labels_coF_meta.merge(
#                 (
#                     d_df_crosstab_labels[col_cls_labels][c_tl]
#                         # .drop('null', axis=1)
#                         .idxmax(axis=1)
#                         .to_frame()
#                         .rename(columns={0: col_pred_})
#                 ),
#                 how='left',
#                 left_on=col_cls_labels,
#                 right_index=True,
#             )
#
#             # Should be rare, but fill just in case?
#             # df_labels_coF_meta[col_pred_] = df_labels_coF_meta[col_pred_].fillna(val_fill_pred_nulls)
#
#             # =====================
#             # Calculate metrics:
#             # ===
#             #         print(
#             #             classification_report(
#             #                 y_true=df_labels_coF_meta[mask_not_null_gt][c_tl],
#             #                 y_pred=df_labels_coF_meta[mask_not_null_gt][col_pred_],
#             #                 zero_division=0,
#             #             )
#             #         )
#             for m_name, metric_ in d_metrics_and_names.items():
#                 d_metrics[col_cls_labels][c_tl] = dict()
#                 try:
#                     d_metrics[col_cls_labels][c_tl][m_name] = metric_(
#                         y_true=df_labels_coF_meta[mask_not_null_gt][c_tl],
#                         y_pred=df_labels_coF_meta[mask_not_null_gt][col_pred_],
#                     )
#                 except TypeError:
#                     d_metrics[col_cls_labels][c_tl][m_name] = metric_(
#                         labels_true=df_labels_coF_meta[mask_not_null_gt][c_tl],
#                         labels_pred=df_labels_coF_meta[mask_not_null_gt][col_pred_],
#                     )
#                 print(f"  Metric {m_name}: {d_metrics[col_cls_labels][c_tl][m_name]:,.4f}")


#
# ~ fin
#
