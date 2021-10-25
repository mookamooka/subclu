"""
Module to cluster embeddings that have already been aggregated
"""
from datetime import datetime, timedelta
import logging
import os
from pathlib import Path
# from typing import Union

import mlflow
import mlflow.sklearn
from mlflow.models.signature import infer_signature

import hydra
from hydra.utils import get_original_cwd
from omegaconf import DictConfig

# import numpy as np
import pandas as pd

from sklearn.pipeline import Pipeline

# NOTE:
# To avoid relative import errors when running from CLI, run script with:
#  * -m flag
#  * no ".py" ending
# Example:
#  python -m subclu.test.test_parallel_jobs
# from ..utils.tqdm_logger import LogTQDM
from ..utils import mlflow_logger
from ..utils.mlflow_logger import MlflowLogger
from ..utils import get_project_subfolder
from ..utils.eda import elapsed_time
# from ..data.data_loaders import LoadSubreddits, LoadPosts


from .clustering_registry import D_CLUSTER_MODELS, D_CLUSTER_PIPELINE


log = logging.getLogger(__name__)


@hydra.main(config_path='../config', config_name="clustering_v0.4.0_base")
def culster_embeddings(cfg: DictConfig) -> object:
    """
    The hydra runner will call the clustering class and apply all the needed
    hyperparameters
    """
    print(f"CFG keys: {cfg.keys()}")

    log.info(f"Define cluster class...")
    cluster = ClusterEmbeddings(
        dict_data_embeddings_to_cluster=cfg['data_embeddings_to_cluster'],
        dict_clustering_algo=cfg['clustering_algo'],
        embeddings_to_cluster=cfg['embeddings_to_cluster'],
        mlflow_tracking_uri=cfg.get('mlflow_tracking_uri', 'sqlite'),
        mlflow_experiment_name=cfg.get('mlflow_experiment_name', 'v0.4.0_use_multi_clustering_test'),
        mlflow_run_name=(
            f"{cfg.get('mlflow_run_name', 'embedding_clustering')}-{datetime.utcnow().strftime('%Y-%m-%d_%H%M%S')}"
        ),
        pipeline_config=cfg.get('pipeline', None),
        logs_path=cfg.get('logs_path', 'logs/ClusterEmbeddings'),
    )

    cluster.run_clustering()
    return cluster


class ClusterEmbeddings:
    """
    Class to orchestrate different strategies to cluster embeddings
    - post-aggregates (e.g., post + comment) and
    - subreddit (e.g., post + comment + subreddit descriptions).
    """
    def __init__(
            self,
            dict_data_embeddings_to_cluster: dict,
            dict_clustering_algo: dict,
            embeddings_to_cluster: str = 'df_sub_level_agg_c_post_comments_and_sub_desc',
            mlflow_tracking_uri: str = 'sqlite',
            mlflow_experiment_name: str = 'v0.4.0_use_multi_clustering_test',
            mlflow_run_name: str = 'embedding_clustering',
            pipeline_config: dict = None,
            logs_path: str = 'logs/ClusterEmbeddings',
            # **kwargs
    ):
        """"""
        self.dict_data_embeddings_to_cluster = dict_data_embeddings_to_cluster
        self.dict_clustering_algo = dict_clustering_algo

        self.embeddings_to_cluster = embeddings_to_cluster

        self.mlflow_experiment_name = mlflow_experiment_name
        self.mlflow_run_name = mlflow_run_name
        self.mlflow_tracking_uri = mlflow_tracking_uri

        # Create path to store local run
        self.path_local_model = None
        self.logs_path = logs_path

        # pipeline to store model
        self.pipeline_config = pipeline_config
        self.pipeline = None

        # use pre-loaded metadata if running in interactive mode
        # self.df_subs_meta = df_subs_meta
        # self.df_posts_meta = df_posts_meta
        # self.df_comments_meta = df_comments_meta

        # self.embeddings_read_fxn = embeddings_read_fxn
        # self.metadata_read_fxn = metadata_read_fxn

        # Set mlflowLogger instance for central tracker
        self.mlf = MlflowLogger(tracking_uri=self.mlflow_tracking_uri)

    def run_clustering(self):
        """"""
        log.info(f"== Start run_aggregation() method ==")
        t_start_run_clustering = datetime.utcnow()

        log.info(f"MLflow tracking URI: {mlflow.get_tracking_uri()}")
        self.mlf.set_experiment(self.mlflow_experiment_name)

        with mlflow.start_run(run_name=self.mlflow_run_name):
            log.info(
                f"=== START CLUSTERING - Process ID {os.getpid()}")
            self.mlf.add_git_hash_to_active_run()
            self.mlf.set_tag_hostname(key='host_name')
            self.mlf.log_param_hostname(key='host_name')
            self.mlf.log_cpu_count()
            self.mlf.log_ram_stats(param=True, only_memory_used=False)

            self._set_path_local_model()

            self._create_and_log_config()

            log.info(f"Creating pipeline...")
            self._create_pipeline()

            log.info(f"Loading embeddings...")
            df_embeddings = self._load_embeddings()

            # TODO(djb): load metadata so we can filter
            self._load_metadata_for_filtering()

            # TODO(djb) apply filtering
            # self._apply_filtering()

            # TODO(djb): Fit clustering algo

            # TODO(djb): log pipeline params
            mlflow_logger.log_pipeline_params(
                self.pipeline,
                save_path=self.path_local_model,
            )

            # TODO(djb): Get predictions for each row

            # TODO(djb): Save predictions & log to mlflow

            # TODO(djb): Get metrics to compare clusters

            # TODO(djb): Save clustering algo & log to mlflow

            # TODO(djb):

            # Log hydra config outputs
            path_hydra_config = self.path_local_model / '.hydra'
            if path_hydra_config.is_dir():
                mlflow.log_artifacts(str(path_hydra_config), 'hydra')

            # Finish logging total time + end mlflow run
            total_fxn_time = elapsed_time(start_time=t_start_run_clustering,
                                          log_label='Total Clustering fxn time', verbose=True)
            mlflow.log_metric('vectorizing_time_minutes',
                              total_fxn_time / timedelta(minutes=1)
                              )
            log.info(f"=== END clustering ===")
            mlflow.end_run()

        if os.getcwd() == get_original_cwd():
            log.info(f"    Removing fileHandler...")
            self._remove_file_logger()

    def _create_pipeline(self):
        """Create pipeline with steps from pipeline config

        When adding steps at the beginning of pipeline, we need to add them from last to first.

        Full pipeline would look something like this:
        pipe_full = Pipeline([
            ('normalize', Normalizer(norm='l2')),
            ('reduce', TruncatedSVD(n_components=50)),
            ('cluster', AgglomerativeClustering(n_clusters=30, affinity='euclidean', connectivity=False)),
        ])
        """
        cls = D_CLUSTER_MODELS[self.dict_clustering_algo['model_name']](
            **self.dict_clustering_algo['model_kwargs']
        )
        # start with only the clustering algo
        self.pipeline = Pipeline([
            ('cluster', cls)
        ])

        # Then add other steps if set in the config
        #  Start with latest step first (reduce first, normalize last)
        l_pipe_steps_to_check = ['reduce', 'normalize']
        if self.pipeline_config is not None:
            log.info(f"Checking custom pipeline config...\n  {self.pipeline_config}")

            for step_ in l_pipe_steps_to_check:
                if self.pipeline_config.get(step_, dict()).get('add_step', False):
                    log.info(f"  Adding step: {step_}")
                    trf_name = self.pipeline_config[step_]['name']
                    trf_kwargs = self.pipeline_config[step_].get('kwargs_', None)

                    # Check if we have custom kwargs for this step:
                    if trf_kwargs is not None:
                        transformer_ = D_CLUSTER_PIPELINE[step_][trf_name](
                            **trf_kwargs
                        )
                    else:
                        transformer_ = D_CLUSTER_PIPELINE[step_][trf_name]()

                    self.pipeline.steps.insert(
                        0,
                        (step_, transformer_),
                    )
        log.info(f"  Pipeline to train:\n  {self.pipeline}")

    def _load_embeddings(self):
        """Load embeddings for clustering"""
        df_embeddings = self.mlf.read_run_artifact(
            run_id=self.dict_data_embeddings_to_cluster['run_uuid'],
            artifact_folder=self.dict_data_embeddings_to_cluster[self.embeddings_to_cluster],
            read_function='pd_parquet',
            cache_locally=True,
        )
        self.l_ix_subs = ['subreddit_name', 'subreddit_id']
        self.l_ix_post = ['subreddit_name', 'subreddit_id', 'post_id']
        self.l_cols_embeddings = [c for c in df_embeddings.columns if c.startswith('embeddings_')]

        r_, c_ = df_embeddings.shape
        log.info(f"{r_:9,.0f} | {c_:5,.0f} <- df_embeddings SHAPE")
        mlflow.log_metrics(
            {'input_embeddings-n_rows': r_,
             'input_embeddings-n_cols': c_}
        )
        return df_embeddings


    def _load_metadata_for_filtering(self):
        """Load metadata to filter embeddings"""
        pass
        # TODO(djb)
        # df_subs = LoadSubreddits(
        #     bucket_name=d_config_text_and_meta['bucket_name'],
        #     folder_path=d_config_text_and_meta['folder_subreddits_text_and_meta'],
        #     folder_posts=d_config_text_and_meta['folder_posts_text_and_meta'],
        #     columns=None,
        #     col_new_manual_topic=col_manual_labels,
        # ).read_apply_transformations_and_merge_post_aggs(
        #     cols_post='post_count_only_',
        #     df_format='dask',
        #     read_fxn='dask',
        #     unique_check=False,
        # )

    def _set_path_local_model(self):
        """Set where to save artifacts locally for this model"""
        if os.getcwd() != get_original_cwd():
            # hydra takes care of creating a custom working directory
            log.info(f"Using hydra's path")
            print(f"  Current working directory : {os.getcwd()}")
            print(f"  Orig working directory    : {get_original_cwd()}")
            self.path_local_model = Path(os.getcwd())
        else:
            # create local path to store artifacts before logging to mlflow
            self.path_local_model = get_project_subfolder(
                f"data/models/cluster_embeddings/{datetime.utcnow().strftime('%Y-%m-%d_%H%M%S')}-{self.mlflow_run_name}"
            )
            Path(self.path_local_model).mkdir(exist_ok=True, parents=True)
            log.info(f"  Local model saving directory: {self.path_local_model}")
            self._init_file_log()

    def _create_and_log_config(self):
        """Convert inputs into a dictionary we can save to replicate the run

        Don't log dfs with meta or raw embeddings! they could be dfs that take up gigs of storage
        """

        # TODO(djb): instead of manually logging everything, use vars(self)
        #  to get all params & filter out:
        #  - things that start with `df_`
        #  - things named `mlf` (it's an mlflowLogger object)
        self.config_to_log_and_store = dict()
        for k_, v_ in vars(self).items():
            try:
                if any([k_.startswith('df_'), k_ == 'mlf', k_ == 'pipeline']):
                    # skip dataframes & some objects that aren't params
                    continue
                elif k_ == 'config_to_log_and_store':
                    # skip this config file b/c it can lead to weird nested recursion
                    continue
                elif any([isinstance(v_, pd.DataFrame),
                          isinstance(v_, logging.FileHandler),
                          isinstance(v_, Path),
                          ]):
                    # Ignore some objects that won't be easy to pickle
                    # would it be better to only keep things that should be easy to pickle instead?
                    #  e.g., string, list, numeric, None ?
                    continue
                else:
                    self.config_to_log_and_store[k_] = v_
            except Exception as e:
                logging.warning(f"Error logging {k_}:\n  {e}")

        # log as params to mlflow
        for k, v in self.config_to_log_and_store.items():
            try:
                # exclude dicts/ConfDicts from mlflow params, but they should be saved
                #  in joblib &/or yaml
                if (v is None) | isinstance(v, (int, float, bool, str)):
                    mlflow.log_param(k, v)
            except Exception as e:
                log.error(f"Error logging {k}:\n  {e}")

        # log as artifact to GCS
        mlflow_logger.save_and_log_config(
            self.config_to_log_and_store,
            local_path=self.path_local_model,
            name_for_artifact_folder='config',
        )

    def _init_file_log(self) -> None:
        """Create a file & FileHandler to log data"""
        # TODO(djb): make sure to remove fileHandler after job is run_aggregation()
        if self.logs_path is not None:
            logger = logging.getLogger()

            path_logs = Path(self.logs_path)
            Path.mkdir(path_logs, parents=False, exist_ok=True)
            self.f_log_file = str(
                path_logs /
                f"{datetime.utcnow().strftime('%Y-%m-%d_%H-%M-%S')}_{self.mlflow_run_name}.log"
            )

            self.fileHandler = logging.FileHandler(self.f_log_file)
            self.fileHandler.setLevel(logging.INFO)

            formatter = logging.Formatter(
                '%(asctime)s | %(levelname)s | "%(message)s"',
                '%Y-%m-%d %H:%M:%S'
            )
            self.fileHandler.setFormatter(formatter)
            logger.addHandler(self.fileHandler)

    def _remove_file_logger(self) -> None:
        """After completing job, remove logging handler to prevent
        info from other jobs getting logged to the same log file
        """
        if self.fileHandler is not None:
            logger = logging.getLogger()
            try:
                logger.removeHandler(self.fileHandler)
            except Exception as e:
                logging.warning(f"Can't remove logger\n{e}")


if __name__ == "__main__":
    culster_embeddings()
