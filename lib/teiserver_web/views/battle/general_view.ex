defmodule TeiserverWeb.Battle.GeneralView do
  use TeiserverWeb, :view

  def colours(), do: StylingHelper.colours(:default)
  def icon(), do: StylingHelper.icon(:default)
end
