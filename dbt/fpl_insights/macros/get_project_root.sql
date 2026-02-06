{% macro get_project_root() %}
    {#-
        Returns the project root path for external CSV file references.

        Resolution order:
        1. FPL_PROJECT_ROOT environment variable (if set)
        2. dbt --vars '{"project_root": "/path/to/project"}' (if passed)
        3. Error with setup instructions

        Usage in models:
            FROM read_csv_auto('{{ get_project_root() }}/data/external/...')
    -#}

    {%- set env_root = env_var('FPL_PROJECT_ROOT', '') -%}
    {%- set var_root = var('project_root', '') -%}

    {%- if env_root != '' -%}
        {{ return(env_root) }}
    {%- elif var_root != '' -%}
        {{ return(var_root) }}
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "Project root not configured. Set FPL_PROJECT_ROOT environment variable or pass --vars '{\"project_root\": \"/path/to/fpl_analytics\"}'"
        ) }}
    {%- endif -%}
{% endmacro %}
